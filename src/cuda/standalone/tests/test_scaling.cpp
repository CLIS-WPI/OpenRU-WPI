// SPDX-FileCopyrightText: Copyright (C) 2026 Software Radio Systems Limited
// SPDX-License-Identifier: BSD-3-Clause-Open-MPI
//
// Scaling study: CPU cores needed vs antenna ports at 100 MHz / 30 kHz SCS,
// with Category-B precoding (layers → ports) and UL combining.

#include "lowphy_cuda.h"
#include "lowphy_pipeline.h"
#include "lowphy_precoding.h"

#include "cpu_catb_precoding.h"
#include "phase_compensation_lut.h"

#include "ocudu/adt/bf16.h"
#include "ocudu/adt/complex.h"
#include "ocudu/ocuduvec/conversion.h"
#include "ocudu/ocudulog/ocudulog.h"
#include "ocudu/ofh/compression/compression_factory.h"
#include "ocudu/ofh/compression/compression_params.h"
#include "ocudu/phy/generic_functions/generic_functions_factories.h"
#include "ocudu/phy/generic_functions/precoding/precoding_factories.h"
#include "ocudu/phy/lower/modulation/modulation_factories.h"
#include "ocudu/phy/lower/modulation/ofdm_demodulator.h"
#include "ocudu/phy/lower/modulation/ofdm_modulator.h"
#include "ocudu/phy/lower/sampling_rate.h"
#include "ocudu/phy/support/re_buffer.h"
#include "ocudu/phy/support/resource_grid.h"
#include "ocudu/phy/support/resource_grid_reader.h"
#include "ocudu/phy/support/resource_grid_writer.h"
#include "ocudu/phy/support/support_factories.h"
#include "ocudu/ran/cyclic_prefix.h"
#include "ocudu/ran/precoding/precoding_constants.h"
#include "ocudu/ran/precoding/precoding_weight_matrix.h"
#include "ocudu/ran/resource_block.h"
#include "ocudu/ran/subcarrier_spacing.h"
#include "ocudu/support/cpu_features.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <memory>
#include <random>
#include <sched.h>
#include <string>
#include <vector>

namespace {

void check_cuda(cudaError_t error, const char* call)
{
  if (error != cudaSuccess) {
    std::fprintf(stderr, "CUDA error in %s: %s\n", call, cudaGetErrorString(error));
    std::exit(1);
  }
}
#define CUDA_CHECK(call) check_cuda((call), #call)

constexpr unsigned NOF_SYMBOLS_PER_SLOT = 14;
constexpr float    CENTER_FREQ_HZ       = 3.5e9f;
constexpr float    GRID_SCALE           = 1.0f / 128.0f;
constexpr unsigned DATA_WIDTH           = 9;
constexpr unsigned LATENCY_ITERS        = 100;
constexpr unsigned WARMUP               = 5;
constexpr double   SLOT_MS              = 0.5;
constexpr unsigned SRATE_HZ             = 122880000u;
constexpr unsigned BW_RB                = 273;

struct latency_stats {
  double p50 = 0, p99 = 0, maxv = 0;
};

latency_stats compute_stats(std::vector<double> v)
{
  latency_stats s;
  if (v.empty()) {
    return s;
  }
  std::sort(v.begin(), v.end());
  s.p50  = v[(v.size() * 50) / 100];
  s.p99  = v[std::min(v.size() - 1, (v.size() * 99) / 100)];
  s.maxv = v.back();
  return s;
}

unsigned cores_needed(double p99_ms)
{
  return static_cast<unsigned>(std::ceil(p99_ms / SLOT_MS));
}

bool pin_cpu(unsigned core)
{
  cpu_set_t set;
  CPU_ZERO(&set);
  CPU_SET(core, &set);
  return sched_setaffinity(0, sizeof(set), &set) == 0;
}

void fill_random_grid(std::vector<ocudu::cbf16_t>& grid, float scale, uint32_t seed)
{
  std::mt19937                          g(seed);
  std::uniform_real_distribution<float> d(-scale, scale);
  for (auto& v : grid) {
    v = ocudu::cbf16_t(d(g), d(g));
  }
}

void fill_weights(std::vector<ocudu::cf_t>& w, unsigned nof_prbs, unsigned nof_ports, unsigned nof_layers, uint32_t seed)
{
  std::mt19937                          g(seed);
  std::uniform_real_distribution<float> d(-1.0f, 1.0f);
  w.resize(static_cast<size_t>(nof_prbs) * nof_ports * nof_layers);
  // Semi-unitary columns: scale by 1/sqrt(ports) so port energy stays O(1).
  const float scale = 1.0f / std::sqrt(static_cast<float>(nof_ports));
  for (auto& c : w) {
    c = ocudu::cf_t(d(g) * scale, d(g) * scale);
  }
}


struct capture_writer : public ocudu::resource_grid_writer {
  unsigned                  nof_ports, nof_symbols, nof_subc;
  std::vector<ocudu::cf_t>& output;
  capture_writer(unsigned p, unsigned s, unsigned c, std::vector<ocudu::cf_t>& o) :
    nof_ports(p), nof_symbols(s), nof_subc(c), output(o)
  {
  }
  unsigned get_nof_ports() const override { return nof_ports; }
  unsigned get_nof_subc() const override { return nof_subc; }
  unsigned get_nof_symbols() const override { return nof_symbols; }
  ocudu::span<const ocudu::cf_t> put(unsigned port, unsigned l, unsigned k_init,
                                     const ocudu::bounded_bitset<ocudu::MAX_NOF_SUBCARRIERS>& mask,
                                     ocudu::span<const ocudu::cf_t> symbols) override
  {
    unsigned count = mask.count(), index = 0;
    for (unsigned k = 0; (k != mask.size()) && (index != count); ++k) {
      if (mask.test(k)) {
        output[((port * nof_symbols + l) * nof_subc) + k_init + k] = symbols[index++];
      }
    }
    return symbols.last(symbols.size() - count);
  }
  ocudu::span<const ocudu::cbf16_t> put(unsigned port, unsigned l, unsigned k_init,
                                        const ocudu::bounded_bitset<ocudu::MAX_NOF_SUBCARRIERS>& mask,
                                        ocudu::span<const ocudu::cbf16_t> symbols) override
  {
    unsigned count = mask.count(), index = 0;
    for (unsigned k = 0; (k != mask.size()) && (index != count); ++k) {
      if (mask.test(k)) {
        output[((port * nof_symbols + l) * nof_subc) + k_init + k] = ocudu::to_cf(symbols[index++]);
      }
    }
    return symbols.last(symbols.size() - count);
  }
  void put(unsigned port, unsigned l, unsigned k_init, ocudu::span<const ocudu::cf_t> symbols) override
  {
    std::copy_n(symbols.begin(), symbols.size(), output.begin() + ((port * nof_symbols + l) * nof_subc) + k_init);
  }
  void put(unsigned port, unsigned l, unsigned k_init, unsigned stride, ocudu::span<const ocudu::cbf16_t> symbols) override
  {
    for (unsigned i = 0; i != symbols.size(); ++i) {
      output[((port * nof_symbols + l) * nof_subc) + k_init + i * stride] = ocudu::to_cf(symbols[i]);
    }
  }
  ocudu::span<ocudu::cbf16_t> get_view(unsigned, unsigned) override { return {}; }
};

/// Pass gate (also used when a few REs trip the mismatch counter):
/// quantity = max |gpu−cpu| over complex floats after bf16→float (hypot of Re/Im);
/// threshold = 1e-3 absolute. The mismatch counter uses a tighter 1e-5 tripwire for
/// diagnostics only; rows with 1–3 mismatches still PASS if max |err| ≤ 1e-3.
constexpr double PASS_MAX_ABS_ERR = 1e-3;
constexpr double MISMATCH_TRIPWIRE = 1e-5;

struct row_result {
  unsigned ports = 0, layers = 0;
  latency_stats gpu_dl, gpu_ul, cpu_dl, cpu_ul;
  latency_stats gpu_precode, cpu_precode, ocudu_prg_precode;
  double   precode_flops      = 0;
  double   precode_max_err    = 0;
  double   combine_max_err    = 0;
  size_t   precode_mismatches = 0;
  size_t   combine_mismatches = 0;
  size_t   opt_vs_ref_mismatches = 0;
  double   opt_vs_ref_max_err = 0;
  bool     pass               = false;
  const char* cpu_precode_impl = "AVX-512 Cat-B (OCUDU apply_precoding_port math; all port counts)";
  bool     stopped_early       = false;
  std::string stop_reason;
};

} // namespace

int main(int argc, char** argv)
{
  unsigned latency_iters = LATENCY_ITERS;
  unsigned cpu_core      = 10;
  const char* csv_path   = "scaling_results.csv";
  for (int i = 1; i < argc; ++i) {
    if ((std::strcmp(argv[i], "--latency-iters") == 0) && (i + 1 < argc)) {
      latency_iters = static_cast<unsigned>(std::strtoul(argv[++i], nullptr, 10));
    } else if ((std::strcmp(argv[i], "--cpu-core") == 0) && (i + 1 < argc)) {
      cpu_core = static_cast<unsigned>(std::strtoul(argv[++i], nullptr, 10));
    } else if ((std::strcmp(argv[i], "--csv") == 0) && (i + 1 < argc)) {
      csv_path = argv[++i];
    }
  }

  ocudulog::init();
  auto& logger = ocudulog::fetch_basic_logger("scaling");
  logger.set_level(ocudulog::basic_levels::warning);

  CUDA_CHECK(cudaSetDevice(0));
  cudaDeviceProp prop{};
  CUDA_CHECK(cudaGetDeviceProperties(&prop, 0));
  if (!pin_cpu(cpu_core)) {
    std::fprintf(stderr, "pin failed\n");
    return 1;
  }

  const ocudu::subcarrier_spacing scs        = ocudu::subcarrier_spacing::kHz30;
  const ocudu::cyclic_prefix      cp         = ocudu::cyclic_prefix::NORMAL;
  const unsigned                  numerology = ocudu::to_numerology_value(scs);
  const ocudu::sampling_rate      srate      = ocudu::sampling_rate::from_Hz(SRATE_HZ);
  const unsigned                  dft_size   = srate.get_dft_size(scs);
  const unsigned                  nof_prbs   = BW_RB;
  const unsigned                  rg_size    = nof_prbs * 12u;
  const unsigned                  prb_size   = 1 + ((24 * DATA_WIDTH + 7) / 8);
  const unsigned                  nof_slots_sf   = ocudu::get_nof_slots_per_subframe(scs);
  const unsigned                  nof_symbols_sf = nof_slots_sf * NOF_SYMBOLS_PER_SLOT;
  const double                    sampling_rate_Hz = static_cast<double>(srate.to_Hz());
  const float                     mod_scale   = 1.0f;
  const float                     demod_scale = 1.0f / std::sqrt(static_cast<float>(rg_size));

  std::vector<unsigned> cp_len(nof_symbols_sf), symbol_start(nof_symbols_sf);
  unsigned              sample_offset = 0;
  for (unsigned s = 0; s != nof_symbols_sf; ++s) {
    cp_len[s]       = cp.get_length(s, scs).to_samples(sampling_rate_Hz);
    symbol_start[s] = sample_offset;
    sample_offset += cp_len[s] + dft_size;
  }
  ocudu::phase_compensation_lut mod_phase(scs, cp, dft_size, CENTER_FREQ_HZ, true);
  ocudu::phase_compensation_lut demod_phase(scs, cp, dft_size, CENTER_FREQ_HZ, false);
  std::vector<lowphy_cf32>      phase_mod(nof_symbols_sf), phase_demod(nof_symbols_sf);
  for (unsigned s = 0; s != nof_symbols_sf; ++s) {
    auto c            = mod_phase.get_coefficient(s);
    phase_mod[s]      = {c.real(), c.imag()};
    c                 = demod_phase.get_coefficient(s);
    phase_demod[s]    = {c.real(), c.imag()};
  }

  auto dft_factory = ocudu::create_dft_processor_factory_fftw_fast();
  if (!dft_factory) {
    std::fprintf(stderr, "FFTW factory missing\n");
    return 1;
  }
  ocudu::ofdm_factory_generic_configuration ofdm_config{dft_factory};
  auto mod_factory   = ocudu::create_ofdm_modulator_factory_generic(ofdm_config);
  auto demod_factory = ocudu::create_ofdm_demodulator_factory_generic(ofdm_config);

  ocudu::ofdm_modulator_configuration modulator_config = {
      .numerology = numerology, .bw_rb = BW_RB, .dft_size = dft_size, .cp = cp,
      .scale = mod_scale, .center_freq_Hz = CENTER_FREQ_HZ};
  ocudu::ofdm_demodulator_configuration demodulator_config = {
      .numerology = numerology, .bw_rb = BW_RB, .dft_size = dft_size, .cp = cp,
      .nof_samples_window_offset = 0, .scale = demod_scale, .center_freq_Hz = CENTER_FREQ_HZ};
  auto slot_modulator   = mod_factory->create_ofdm_slot_modulator(modulator_config);
  auto slot_demodulator = demod_factory->create_ofdm_slot_demodulator(demodulator_config);
  const unsigned slot_index   = 0;
  const unsigned slot_start   = symbol_start[0];
  const unsigned slot_samples = slot_modulator->get_slot_size(0);

  auto precoder_factory = ocudu::create_channel_precoder_factory("avx512");
  std::unique_ptr<ocudu::channel_precoder> ocudu_precoder =
      precoder_factory ? precoder_factory->create() : nullptr;

  std::printf("# Scaling study: 100 MHz, 30 kHz SCS, Cat-B precoding [MEASURED] H100 compute-only\n");
  std::printf("Device: %s; CPU core %u; FFTW + AVX-512 BFP; slot=%.1f ms\n", prop.name, cpu_core, SLOT_MS);
  std::printf("Production OCUDU call site: resource_grid_mapper_impl.cpp:245-263\n"
              "  (pre-stored get_prg_coefficients + apply_precoding on RE views).\n"
              "Timed CPU path: AVX-512 strip over REs with per-PRB weights — same kernel math as\n"
              "  channel_precoder_avx512.cpp:221-269 (apply_precoding_port), for ALL port counts.\n"
              "  (Calling OCUDU apply_precoding once per Cat-B PRB of 12 REs cannot amortize AVX;\n"
              "   that pattern is still exercised for fidelity and reported as ocudu_prg_p50.)\n"
              "Scalar reference (channel_precoder_generic.cpp:9-30) is correctness-only.\n"
              "Pass tolerance: max |gpu-cpu| after bf16→float ≤ %.0e (mismatch tripwire %.0e is diagnostic).\n"
              "GPU precoding: custom CUDA Cat-B kernel; Jetson not claimed\n\n",
              PASS_MAX_ABS_ERR,
              MISMATCH_TRIPWIRE);
  if (!ocudu_precoder) {
    std::fprintf(stderr, "OCUDU avx512 channel_precoder unavailable\n");
    return 1;
  }

  const std::vector<unsigned> port_counts  = {2, 4, 8, 16, 32, 64};
  const std::vector<unsigned> layer_counts = {2, 4};

  std::vector<row_result> results;
  bool                    stop_ports = false;
  std::string             stop_reason;

  cudaStream_t stream = nullptr;
  CUDA_CHECK(cudaStreamCreate(&stream));

  for (unsigned ports : port_counts) {
    if (stop_ports) {
      break;
    }
    for (unsigned layers : layer_counts) {
      if (layers > ports) {
        continue;
      }

      row_result row;
      row.ports  = ports;
      row.layers = layers;
      row.precode_flops = cpu_catb::flop_count_precode(ports, layers, nof_prbs);

      const size_t layer_grid_elems = static_cast<size_t>(layers) * NOF_SYMBOLS_PER_SLOT * rg_size;
      const size_t port_grid_elems  = static_cast<size_t>(ports) * NOF_SYMBOLS_PER_SLOT * rg_size;
      const size_t layer_comp_bytes =
          static_cast<size_t>(layers) * NOF_SYMBOLS_PER_SLOT * nof_prbs * prb_size;
      const size_t port_ci16_bytes = static_cast<size_t>(ports) * slot_samples * sizeof(int16_t) * 2u;
      const size_t weights_elems   = static_cast<size_t>(nof_prbs) * ports * layers;

      // Estimate device memory: layer+port grids, weights, ci16, compressed, plans scratch ~2x
      const size_t est_bytes = layer_grid_elems * 4 + port_grid_elems * 4 + port_grid_elems * 8 +
                               weights_elems * sizeof(lowphy_cf32) + port_ci16_bytes + layer_comp_bytes +
                               static_cast<size_t>(ports) * NOF_SYMBOLS_PER_SLOT * dft_size * 8 * 2;
      if (est_bytes > static_cast<size_t>(12) * 1024 * 1024 * 1024) {
        row.stopped_early = true;
        row.stop_reason   = "estimated device memory > 12 GiB";
        results.push_back(row);
        stop_ports  = true;
        stop_reason = row.stop_reason;
        break;
      }

      std::vector<ocudu::cbf16_t> layer_grid(layer_grid_elems);
      fill_random_grid(layer_grid, GRID_SCALE, 0x1000u + ports * 16 + layers);
      std::vector<ocudu::cf_t> weights;
      fill_weights(weights, nof_prbs, ports, layers, 0x2000u + ports);
      cpu_catb::WeightBank weight_bank;
      weight_bank.build(weights, nof_prbs, ports, layers);
      std::vector<ocudu::cf_t> layer_grid_cf;
      cpu_catb::layers_cbf16_to_cf(layer_grid_cf, layer_grid, layers, rg_size);

      auto compressor = ocudu::ofh::create_iq_compressor(ocudu::ofh::compression_type::BFP, logger, 1.0f, "avx512");
      auto decompressor =
          ocudu::ofh::create_iq_decompressor(ocudu::ofh::compression_type::BFP, logger, "avx512");
      ocudu::ofh::ru_compression_params params{ocudu::ofh::compression_type::BFP, DATA_WIDTH};

      std::vector<uint8_t> layer_compressed(layer_comp_bytes);
      for (unsigned layer = 0; layer != layers; ++layer) {
        for (unsigned symbol = 0; symbol != NOF_SYMBOLS_PER_SLOT; ++symbol) {
          size_t go = (static_cast<size_t>(layer) * NOF_SYMBOLS_PER_SLOT + symbol) * rg_size;
          size_t co = (static_cast<size_t>(layer) * NOF_SYMBOLS_PER_SLOT + symbol) * nof_prbs * prb_size;
          compressor->compress(ocudu::span<uint8_t>(layer_compressed.data() + co, nof_prbs * prb_size),
                               ocudu::span<const ocudu::cbf16_t>(layer_grid.data() + go, rg_size),
                               params);
        }
      }

      // ---- Correctness: GPU precoding vs CPU ----
      uint16_t*    d_layer_cbf16 = nullptr;
      uint16_t*    d_port_cbf16  = nullptr;
      lowphy_cf32* d_weights     = nullptr;
      CUDA_CHECK(cudaMalloc(&d_layer_cbf16, layer_grid_elems * sizeof(ocudu::cbf16_t)));
      CUDA_CHECK(cudaMalloc(&d_port_cbf16, port_grid_elems * sizeof(ocudu::cbf16_t)));
      CUDA_CHECK(cudaMalloc(&d_weights, weights_elems * sizeof(lowphy_cf32)));
      CUDA_CHECK(cudaMemcpy(d_layer_cbf16, layer_grid.data(), layer_grid_elems * sizeof(ocudu::cbf16_t),
                            cudaMemcpyHostToDevice));
      std::vector<lowphy_cf32> weights_cf(weights_elems);
      for (size_t i = 0; i != weights_elems; ++i) {
        weights_cf[i] = {weights[i].real(), weights[i].imag()};
      }
      CUDA_CHECK(cudaMemcpy(d_weights, weights_cf.data(), weights_elems * sizeof(lowphy_cf32), cudaMemcpyHostToDevice));

      // Stage-only GPU precoding timing (weights+input already on device).
      for (unsigned i = 0; i != WARMUP; ++i) {
        lowphy_catb_precode(
            d_layer_cbf16, d_weights, d_port_cbf16, layers, ports, NOF_SYMBOLS_PER_SLOT, nof_prbs, stream);
        CUDA_CHECK(cudaStreamSynchronize(stream));
      }
      cudaEvent_t pev0, pev1;
      CUDA_CHECK(cudaEventCreate(&pev0));
      CUDA_CHECK(cudaEventCreate(&pev1));
      std::vector<double> gpu_pre_ms;
      for (unsigned i = 0; i != latency_iters; ++i) {
        CUDA_CHECK(cudaEventRecord(pev0, stream));
        lowphy_catb_precode(
            d_layer_cbf16, d_weights, d_port_cbf16, layers, ports, NOF_SYMBOLS_PER_SLOT, nof_prbs, stream);
        CUDA_CHECK(cudaEventRecord(pev1, stream));
        CUDA_CHECK(cudaEventSynchronize(pev1));
        float ms = 0;
        CUDA_CHECK(cudaEventElapsedTime(&ms, pev0, pev1));
        gpu_pre_ms.push_back(ms);
      }
      row.gpu_precode = compute_stats(gpu_pre_ms);
      CUDA_CHECK(cudaEventDestroy(pev0));
      CUDA_CHECK(cudaEventDestroy(pev1));

      std::vector<ocudu::cbf16_t> gpu_ported(port_grid_elems);
      CUDA_CHECK(cudaMemcpy(gpu_ported.data(), d_port_cbf16, port_grid_elems * sizeof(ocudu::cbf16_t),
                            cudaMemcpyDeviceToHost));

      // Optimized CPU path vs scalar reference (correctness of the harness itself).
      std::vector<ocudu::cbf16_t> cpu_opt;
      std::vector<ocudu::cbf16_t> cpu_ref;
      cpu_catb::precode_optimized(cpu_opt, layer_grid_cf, weight_bank, ocudu_precoder.get());
      cpu_catb::precode_reference(cpu_ref, layer_grid_cf, weight_bank);
      for (size_t i = 0; i != port_grid_elems; ++i) {
        const ocudu::cf_t o = ocudu::to_cf(cpu_opt[i]);
        const ocudu::cf_t r = ocudu::to_cf(cpu_ref[i]);
        const double err =
            std::hypot(static_cast<double>(o.real() - r.real()), static_cast<double>(o.imag() - r.imag()));
        if (err > MISMATCH_TRIPWIRE) {
          ++row.opt_vs_ref_mismatches;
        }
        row.opt_vs_ref_max_err = std::max(row.opt_vs_ref_max_err, err);
      }

      // GPU vs optimized CPU in float domain.
      for (size_t i = 0; i != port_grid_elems; ++i) {
        const ocudu::cf_t g = ocudu::to_cf(gpu_ported[i]);
        const ocudu::cf_t c = ocudu::to_cf(cpu_opt[i]);
        const double err =
            std::hypot(static_cast<double>(g.real() - c.real()), static_cast<double>(g.imag() - c.imag()));
        if (err > MISMATCH_TRIPWIRE) {
          ++row.precode_mismatches;
        }
        row.precode_max_err = std::max(row.precode_max_err, err);
      }

      // Stage-only CPU precoding timing (cf conversion done once above; weights pre-built).
      {
        std::vector<ocudu::cbf16_t> timed_out;
        for (unsigned i = 0; i != WARMUP; ++i) {
          cpu_catb::precode_optimized(timed_out, layer_grid_cf, weight_bank, ocudu_precoder.get());
        }
        std::vector<double> cpu_pre_ms;
        for (unsigned i = 0; i != latency_iters; ++i) {
          auto t0 = std::chrono::steady_clock::now();
          cpu_catb::precode_optimized(timed_out, layer_grid_cf, weight_bank, ocudu_precoder.get());
          auto t1 = std::chrono::steady_clock::now();
          cpu_pre_ms.push_back(std::chrono::duration<double, std::milli>(t1 - t0).count());
        }
        row.cpu_precode = compute_stats(cpu_pre_ms);

        // OCUDU PRG-view path (production call pattern) — fidelity + overhead contrast.
        for (unsigned i = 0; i != WARMUP; ++i) {
          cpu_catb::precode_ocudu_prg_views(timed_out, layer_grid_cf, weight_bank, ocudu_precoder.get());
        }
        std::vector<double> ocudu_pre_ms;
        for (unsigned i = 0; i != latency_iters; ++i) {
          auto t0 = std::chrono::steady_clock::now();
          cpu_catb::precode_ocudu_prg_views(timed_out, layer_grid_cf, weight_bank, ocudu_precoder.get());
          auto t1 = std::chrono::steady_clock::now();
          ocudu_pre_ms.push_back(std::chrono::duration<double, std::milli>(t1 - t0).count());
        }
        row.ocudu_prg_precode = compute_stats(ocudu_pre_ms);

        const double gflops =
            (row.precode_flops / 1e9) / std::max(row.cpu_precode.p50 / 1e3, 1e-12);
        std::printf("  precode stage ports=%u layers=%u  FLOPs=%.3e  "
                    "CPU_AVX p50=%.4f ms (%.1f GFLOP/s)  OCUDU_PRG p50=%.4f ms  GPU p50=%.4f ms  "
                    "opt_vs_ref_mis=%zu  gpu_vs_cpu_mis=%zu max|err|=%.3e\n",
                    ports,
                    layers,
                    row.precode_flops,
                    row.cpu_precode.p50,
                    gflops,
                    row.ocudu_prg_precode.p50,
                    row.gpu_precode.p50,
                    row.opt_vs_ref_mismatches,
                    row.precode_mismatches,
                    row.precode_max_err);
      }

      // ---- GPU DL full chain timing: H2D layers_comp -> decompress -> precode -> OFDM -> D2H ----
      // Reuse pipeline buffers manually for flexibility with layers != ports.
      uint8_t*  d_comp   = nullptr;
      int16_t*  d_ci16   = nullptr;
      uint8_t*  d_empty  = nullptr;
      lowphy_cf32* d_phase = nullptr;
      unsigned* d_cp = nullptr;
      unsigned* d_ss = nullptr;
      CUDA_CHECK(cudaMalloc(&d_comp, layer_comp_bytes + 2));
      CUDA_CHECK(cudaMemset(d_comp, 0, layer_comp_bytes + 2));
      CUDA_CHECK(cudaMalloc(&d_ci16, port_ci16_bytes));
      CUDA_CHECK(cudaMalloc(&d_empty, ports));
      CUDA_CHECK(cudaMemset(d_empty, 0, ports));
      CUDA_CHECK(cudaMalloc(&d_phase, nof_symbols_sf * sizeof(lowphy_cf32)));
      CUDA_CHECK(cudaMalloc(&d_cp, nof_symbols_sf * sizeof(unsigned)));
      CUDA_CHECK(cudaMalloc(&d_ss, nof_symbols_sf * sizeof(unsigned)));
      CUDA_CHECK(cudaMemcpy(d_phase, phase_mod.data(), nof_symbols_sf * sizeof(lowphy_cf32), cudaMemcpyHostToDevice));
      CUDA_CHECK(cudaMemcpy(d_cp, cp_len.data(), nof_symbols_sf * sizeof(unsigned), cudaMemcpyHostToDevice));
      CUDA_CHECK(cudaMemcpy(d_ss, symbol_start.data(), nof_symbols_sf * sizeof(unsigned), cudaMemcpyHostToDevice));

      lowphy_ofdm_plan* mod_plan = lowphy_ofdm_plan_create(dft_size, ports, NOF_SYMBOLS_PER_SLOT, true);
      if (!mod_plan) {
        std::fprintf(stderr, "cuFFT mod plan failed for %u ports\n", ports);
        return 1;
      }

      std::vector<uint8_t> h_comp = layer_compressed;
      std::vector<int16_t> h_ci16(port_ci16_bytes / sizeof(int16_t));
      CUDA_CHECK(cudaHostRegister(h_comp.data(), layer_comp_bytes, cudaHostRegisterDefault));
      CUDA_CHECK(cudaHostRegister(h_ci16.data(), port_ci16_bytes, cudaHostRegisterDefault));

      auto gpu_dl_once = [&]() {
        CUDA_CHECK(cudaMemcpyAsync(d_comp, h_comp.data(), layer_comp_bytes, cudaMemcpyHostToDevice, stream));
        lowphy_bfp_decompress(d_comp, d_layer_cbf16, layers, NOF_SYMBOLS_PER_SLOT, nof_prbs, DATA_WIDTH, stream);
        lowphy_catb_precode(
            d_layer_cbf16, d_weights, d_port_cbf16, layers, ports, NOF_SYMBOLS_PER_SLOT, nof_prbs, stream);
        lowphy_ofdm_mod_params mod{};
        mod.plan = mod_plan;
        mod.grid = d_port_cbf16;
        mod.out  = d_ci16;
        mod.port_empty = d_empty;
        mod.phase = d_phase;
        mod.cp_len = d_cp;
        mod.symbol_start = d_ss;
        mod.nof_ports = ports;
        mod.nof_symbols_per_slot = NOF_SYMBOLS_PER_SLOT;
        mod.dft_size = dft_size;
        mod.bw_rb = BW_RB;
        mod.slot_index = slot_index;
        mod.slot_start = slot_start;
        mod.slot_samples = slot_samples;
        mod.scale = mod_scale;
        lowphy_ofdm_mod_pre(mod, stream);
        lowphy_ofdm_mod_fft(mod, stream);
        lowphy_ofdm_mod_post(mod, stream);
        CUDA_CHECK(cudaMemcpyAsync(h_ci16.data(), d_ci16, port_ci16_bytes, cudaMemcpyDeviceToHost, stream));
      };

      for (unsigned i = 0; i != WARMUP; ++i) {
        gpu_dl_once();
        CUDA_CHECK(cudaStreamSynchronize(stream));
      }
      cudaEvent_t ev0, ev1;
      CUDA_CHECK(cudaEventCreate(&ev0));
      CUDA_CHECK(cudaEventCreate(&ev1));
      std::vector<double> gpu_dl_ms;
      for (unsigned i = 0; i != latency_iters; ++i) {
        CUDA_CHECK(cudaEventRecord(ev0, stream));
        gpu_dl_once();
        CUDA_CHECK(cudaEventRecord(ev1, stream));
        CUDA_CHECK(cudaEventSynchronize(ev1));
        float ms = 0;
        CUDA_CHECK(cudaEventElapsedTime(&ms, ev0, ev1));
        gpu_dl_ms.push_back(ms);
      }
      row.gpu_dl = compute_stats(gpu_dl_ms);

      // ---- GPU UL: H2D ci16 -> demod -> combine -> compress -> D2H ----
      lowphy_ofdm_plan* demod_plan = lowphy_ofdm_plan_create(dft_size, ports, NOF_SYMBOLS_PER_SLOT, false);
      lowphy_cf32*      d_port_cf32 = nullptr;
      uint8_t*          d_layer_comp = nullptr;
      CUDA_CHECK(cudaMalloc(&d_port_cf32, port_grid_elems * sizeof(lowphy_cf32)));
      CUDA_CHECK(cudaMalloc(&d_layer_comp, layer_comp_bytes));
      std::vector<uint8_t> h_layer_out(layer_comp_bytes);
      CUDA_CHECK(cudaHostRegister(h_layer_out.data(), layer_comp_bytes, cudaHostRegisterDefault));
      // Seed UL input from last GPU DL output (ci16 already in h_ci16).
      std::vector<int16_t> h_ci16_in = h_ci16;
      CUDA_CHECK(cudaHostRegister(h_ci16_in.data(), port_ci16_bytes, cudaHostRegisterDefault));
      CUDA_CHECK(cudaMemcpy(d_phase, phase_demod.data(), nof_symbols_sf * sizeof(lowphy_cf32), cudaMemcpyHostToDevice));

      auto gpu_ul_once = [&]() {
        CUDA_CHECK(cudaMemcpyAsync(d_ci16, h_ci16_in.data(), port_ci16_bytes, cudaMemcpyHostToDevice, stream));
        lowphy_ofdm_demod_params dem{};
        dem.plan = demod_plan;
        dem.in = d_ci16;
        dem.grid = d_port_cf32;
        dem.phase = d_phase;
        dem.window_phase = nullptr;
        dem.cp_len = d_cp;
        dem.symbol_start = d_ss;
        dem.nof_ports = ports;
        dem.nof_symbols_per_slot = NOF_SYMBOLS_PER_SLOT;
        dem.dft_size = dft_size;
        dem.bw_rb = BW_RB;
        dem.slot_index = slot_index;
        dem.slot_start = slot_start;
        dem.slot_samples = slot_samples;
        dem.window_offset = 0;
        dem.scale = demod_scale;
        lowphy_ofdm_demod_pre(dem, stream);
        lowphy_ofdm_demod_fft(dem, stream);
        lowphy_ofdm_demod_post(dem, stream);
        lowphy_catb_combine(
            d_port_cf32, d_weights, d_layer_cbf16, layers, ports, NOF_SYMBOLS_PER_SLOT, nof_prbs, stream);
        lowphy_bfp_compress(d_layer_cbf16, d_layer_comp, layers, NOF_SYMBOLS_PER_SLOT, nof_prbs, DATA_WIDTH, stream);
        CUDA_CHECK(cudaMemcpyAsync(h_layer_out.data(), d_layer_comp, layer_comp_bytes, cudaMemcpyDeviceToHost, stream));
      };

      for (unsigned i = 0; i != WARMUP; ++i) {
        gpu_ul_once();
        CUDA_CHECK(cudaStreamSynchronize(stream));
      }
      std::vector<double> gpu_ul_ms;
      for (unsigned i = 0; i != latency_iters; ++i) {
        CUDA_CHECK(cudaEventRecord(ev0, stream));
        gpu_ul_once();
        CUDA_CHECK(cudaEventRecord(ev1, stream));
        CUDA_CHECK(cudaEventSynchronize(ev1));
        float ms = 0;
        CUDA_CHECK(cudaEventElapsedTime(&ms, ev0, ev1));
        gpu_ul_ms.push_back(ms);
      }
      row.gpu_ul = compute_stats(gpu_ul_ms);

      // Combine correctness: optimized AVX-512 vs scalar ref, and GPU vs optimized.
      {
        std::vector<ocudu::cf_t> port_cf(port_grid_elems);
        CUDA_CHECK(cudaMemcpy(port_cf.data(), d_port_cf32, port_grid_elems * sizeof(lowphy_cf32), cudaMemcpyDeviceToHost));
        std::vector<ocudu::cbf16_t> cpu_combined_opt;
        std::vector<ocudu::cbf16_t> cpu_combined_ref;
        cpu_catb::combine_optimized(cpu_combined_opt, port_cf, weight_bank);
        cpu_catb::combine_reference(cpu_combined_ref, port_cf, weight_bank);
        for (size_t i = 0; i != layer_grid_elems; ++i) {
          const ocudu::cf_t o = ocudu::to_cf(cpu_combined_opt[i]);
          const ocudu::cf_t r = ocudu::to_cf(cpu_combined_ref[i]);
          const double err =
              std::hypot(static_cast<double>(o.real() - r.real()), static_cast<double>(o.imag() - r.imag()));
          if (err > MISMATCH_TRIPWIRE) {
            ++row.opt_vs_ref_mismatches;
          }
          row.opt_vs_ref_max_err = std::max(row.opt_vs_ref_max_err, err);
        }
        std::vector<ocudu::cbf16_t> gpu_combined(layer_grid_elems);
        lowphy_catb_combine(
            d_port_cf32, d_weights, d_layer_cbf16, layers, ports, NOF_SYMBOLS_PER_SLOT, nof_prbs, stream);
        CUDA_CHECK(cudaMemcpy(gpu_combined.data(), d_layer_cbf16, layer_grid_elems * sizeof(ocudu::cbf16_t),
                              cudaMemcpyDeviceToHost));
        CUDA_CHECK(cudaStreamSynchronize(stream));
        for (size_t i = 0; i != layer_grid_elems; ++i) {
          const ocudu::cf_t g = ocudu::to_cf(gpu_combined[i]);
          const ocudu::cf_t c = ocudu::to_cf(cpu_combined_opt[i]);
          const double err =
              std::hypot(static_cast<double>(g.real() - c.real()), static_cast<double>(g.imag() - c.imag()));
          if (err > MISMATCH_TRIPWIRE) {
            ++row.combine_mismatches;
          }
          row.combine_max_err = std::max(row.combine_max_err, err);
        }
      }

      // ---- CPU DL/UL timing (FFTW + AVX-512 BFP + production-style precoder) ----
      std::vector<ocudu::cbf16_t> dec_layers(layer_grid_elems);
      std::vector<ocudu::cf_t>    dec_layers_cf(layer_grid_elems);
      std::vector<ocudu::cbf16_t> precoded;
      std::vector<ocudu::cf_t>    slot_cf(slot_samples);
      std::vector<ocudu::ci16_t>  out_ci16(static_cast<size_t>(ports) * slot_samples);
      auto grid_factory = ocudu::create_resource_grid_factory();
      auto timed_grid   = grid_factory->create(ports, NOF_SYMBOLS_PER_SLOT, rg_size);

      auto cpu_dl_once = [&]() {
        for (unsigned layer = 0; layer != layers; ++layer) {
          for (unsigned symbol = 0; symbol != NOF_SYMBOLS_PER_SLOT; ++symbol) {
            size_t go = (static_cast<size_t>(layer) * NOF_SYMBOLS_PER_SLOT + symbol) * rg_size;
            size_t co = (static_cast<size_t>(layer) * NOF_SYMBOLS_PER_SLOT + symbol) * nof_prbs * prb_size;
            decompressor->decompress(ocudu::span<ocudu::cbf16_t>(dec_layers.data() + go, rg_size),
                                     ocudu::span<const uint8_t>(layer_compressed.data() + co, nof_prbs * prb_size),
                                     params);
          }
        }
        cpu_catb::layers_cbf16_to_cf(dec_layers_cf, dec_layers, layers, rg_size);
        cpu_catb::precode_optimized(precoded, dec_layers_cf, weight_bank, ocudu_precoder.get());
        for (unsigned port = 0; port != ports; ++port) {
          for (unsigned symbol = 0; symbol != NOF_SYMBOLS_PER_SLOT; ++symbol) {
            auto view = timed_grid->get_writer().get_view(port, symbol);
            std::copy_n(precoded.data() + (static_cast<size_t>(port) * NOF_SYMBOLS_PER_SLOT + symbol) * rg_size,
                        rg_size,
                        view.begin());
          }
        }
        for (unsigned port = 0; port != ports; ++port) {
          slot_modulator->modulate(ocudu::span<ocudu::cf_t>(slot_cf), timed_grid->get_reader(), port, slot_index);
          ocudu::ocuduvec::convert(ocudu::span<ocudu::ci16_t>(out_ci16.data() + port * slot_samples, slot_samples),
                                   ocudu::span<const ocudu::cf_t>(slot_cf),
                                   32767.0f);
        }
      };

      for (unsigned i = 0; i != WARMUP; ++i) {
        cpu_dl_once();
      }
      std::vector<double> cpu_dl_ms;
      for (unsigned i = 0; i != latency_iters; ++i) {
        auto t0 = std::chrono::steady_clock::now();
        cpu_dl_once();
        auto t1 = std::chrono::steady_clock::now();
        cpu_dl_ms.push_back(std::chrono::duration<double, std::milli>(t1 - t0).count());
      }
      row.cpu_dl = compute_stats(cpu_dl_ms);

      std::vector<ocudu::cf_t> demod_in(static_cast<size_t>(ports) * slot_samples);
      ocudu::ocuduvec::convert(ocudu::span<ocudu::cf_t>(demod_in), ocudu::span<const ocudu::ci16_t>(out_ci16), 32767.0f);
      std::vector<ocudu::cf_t>    demod_grid(port_grid_elems);
      std::vector<ocudu::cbf16_t> combined;
      std::vector<uint8_t>        ul_comp(layer_comp_bytes);
      capture_writer              writer(ports, NOF_SYMBOLS_PER_SLOT, rg_size, demod_grid);

      auto cpu_ul_once = [&]() {
        for (unsigned port = 0; port != ports; ++port) {
          slot_demodulator->demodulate(
              writer, ocudu::span<const ocudu::cf_t>(demod_in.data() + port * slot_samples, slot_samples), port, slot_index);
        }
        cpu_catb::combine_optimized(combined, demod_grid, weight_bank);
        for (unsigned layer = 0; layer != layers; ++layer) {
          for (unsigned symbol = 0; symbol != NOF_SYMBOLS_PER_SLOT; ++symbol) {
            size_t go = (static_cast<size_t>(layer) * NOF_SYMBOLS_PER_SLOT + symbol) * rg_size;
            size_t co = (static_cast<size_t>(layer) * NOF_SYMBOLS_PER_SLOT + symbol) * nof_prbs * prb_size;
            compressor->compress(ocudu::span<uint8_t>(ul_comp.data() + co, nof_prbs * prb_size),
                                 ocudu::span<const ocudu::cbf16_t>(combined.data() + go, rg_size),
                                 params);
          }
        }
      };
      for (unsigned i = 0; i != WARMUP; ++i) {
        cpu_ul_once();
      }
      std::vector<double> cpu_ul_ms;
      for (unsigned i = 0; i != latency_iters; ++i) {
        auto t0 = std::chrono::steady_clock::now();
        cpu_ul_once();
        auto t1 = std::chrono::steady_clock::now();
        cpu_ul_ms.push_back(std::chrono::duration<double, std::milli>(t1 - t0).count());
      }
      row.cpu_ul = compute_stats(cpu_ul_ms);

      // Pass: max |err| ≤ PASS_MAX_ABS_ERR (1e-3). Mismatch counts at 1e-5 are diagnostic.
      row.pass = (row.precode_max_err <= PASS_MAX_ABS_ERR) && (row.combine_max_err <= PASS_MAX_ABS_ERR) &&
                 (row.opt_vs_ref_max_err <= PASS_MAX_ABS_ERR);
      results.push_back(row);

      std::printf("ports=%u layers=%u  GPU DL p50/p99=%.4f/%.4f  UL=%.4f/%.4f  "
                  "CPU DL=%.4f/%.4f UL=%.4f/%.4f  precode_mis=%zu(max|e|=%.3e) combine_mis=%zu(max|e|=%.3e) [%s]\n",
                  ports,
                  layers,
                  row.gpu_dl.p50,
                  row.gpu_dl.p99,
                  row.gpu_ul.p50,
                  row.gpu_ul.p99,
                  row.cpu_dl.p50,
                  row.cpu_dl.p99,
                  row.cpu_ul.p50,
                  row.cpu_ul.p99,
                  row.precode_mismatches,
                  row.precode_max_err,
                  row.combine_mismatches,
                  row.combine_max_err,
                  row.pass ? "PASS" : "FAIL");

      // Cleanup this config
      lowphy_ofdm_plan_destroy(mod_plan);
      lowphy_ofdm_plan_destroy(demod_plan);
      cudaFree(d_layer_cbf16);
      cudaFree(d_port_cbf16);
      cudaFree(d_weights);
      cudaFree(d_comp);
      cudaFree(d_ci16);
      cudaFree(d_empty);
      cudaFree(d_phase);
      cudaFree(d_cp);
      cudaFree(d_ss);
      cudaFree(d_port_cf32);
      cudaFree(d_layer_comp);
      cudaHostUnregister(h_comp.data());
      cudaHostUnregister(h_ci16.data());
      cudaHostUnregister(h_ci16_in.data());
      cudaHostUnregister(h_layer_out.data());
      CUDA_CHECK(cudaEventDestroy(ev0));
      CUDA_CHECK(cudaEventDestroy(ev1));

      if (row.gpu_dl.p50 > 0.5 * SLOT_MS && row.gpu_ul.p50 > 0.5 * SLOT_MS) {
        stop_ports  = true;
        stop_reason =
            "both GPU DL and UL p50 exceed 50% of the 0.5 ms slot; further ports are not meaningful for realtime";
        break;
      }
    }
  }

  CUDA_CHECK(cudaStreamDestroy(stream));

  // Find thresholds
  int cpu_miss_ports = -1;
  int gpu_half_ports = -1;
  for (const auto& r : results) {
    if (!r.stopped_early) {
      if (cpu_miss_ports < 0 && (r.cpu_dl.p99 > SLOT_MS || r.cpu_ul.p99 > SLOT_MS ||
                                (r.cpu_dl.p99 + r.cpu_ul.p99) > SLOT_MS)) {
        cpu_miss_ports = static_cast<int>(r.ports);
      }
      // Use p50 for the 50%-slot threshold so a single p99 outlier cannot trip it.
      if (gpu_half_ports < 0 && (r.gpu_dl.p50 > 0.5 * SLOT_MS || r.gpu_ul.p50 > 0.5 * SLOT_MS)) {
        gpu_half_ports = static_cast<int>(r.ports);
      }
    }
  }

  std::printf("\n## Results table (100 MHz, 30 kHz SCS) [MEASURED] H100 compute-only\n\n");
  std::printf("| Ports | Layers | GPU DL p50/p99/max | GPU UL p50/p99/max | "
              "CPU DL p50/p99/max | CPU UL p50/p99/max | GPU p99/p50 DL|UL | CPU p99/p50 DL|UL | "
              "cores_needed | GPU frac slot DL|UL | Pass |\n");
  std::printf("|---:|---:|---|---|---|---|---|---|---:|---|:---:|\n");

  std::ofstream csv(csv_path);
  csv << "ports,layers,gpu_dl_p50_ms,gpu_dl_p99_ms,gpu_dl_max_ms,gpu_ul_p50_ms,gpu_ul_p99_ms,gpu_ul_max_ms,"
         "cpu_dl_p50_ms,cpu_dl_p99_ms,cpu_dl_max_ms,cpu_ul_p50_ms,cpu_ul_p99_ms,cpu_ul_max_ms,"
         "gpu_precode_p50_ms,cpu_precode_p50_ms,ocudu_prg_precode_p50_ms,precode_flops,"
         "gpu_dl_p99_p50,gpu_ul_p99_p50,cpu_dl_p99_p50,cpu_ul_p99_p50,"
         "cores_needed_dl_ul,gpu_frac_slot_dl,gpu_frac_slot_ul,cpu_precode_impl,precode_mismatches,"
         "combine_mismatches,precode_max_err,combine_max_err,opt_vs_ref_max_err,pass\n";

  for (const auto& r : results) {
    if (r.stopped_early) {
      continue;
    }
    const double gdl_r = r.gpu_dl.p50 > 0 ? r.gpu_dl.p99 / r.gpu_dl.p50 : 0;
    const double gul_r = r.gpu_ul.p50 > 0 ? r.gpu_ul.p99 / r.gpu_ul.p50 : 0;
    const double cdl_r = r.cpu_dl.p50 > 0 ? r.cpu_dl.p99 / r.cpu_dl.p50 : 0;
    const double cul_r = r.cpu_ul.p50 > 0 ? r.cpu_ul.p99 / r.cpu_ul.p50 : 0;
    const unsigned cores = cores_needed(r.cpu_dl.p99 + r.cpu_ul.p99);
    const double frac_dl = r.gpu_dl.p99 / SLOT_MS;
    const double frac_ul = r.gpu_ul.p99 / SLOT_MS;
    std::printf("| %u | %u | %.4f/%.4f/%.4f | %.4f/%.4f/%.4f | %.4f/%.4f/%.4f | %.4f/%.4f/%.4f | "
                "%.2f|%.2f | %.2f|%.2f | %u | %.3f|%.3f | %s |\n",
                r.ports,
                r.layers,
                r.gpu_dl.p50,
                r.gpu_dl.p99,
                r.gpu_dl.maxv,
                r.gpu_ul.p50,
                r.gpu_ul.p99,
                r.gpu_ul.maxv,
                r.cpu_dl.p50,
                r.cpu_dl.p99,
                r.cpu_dl.maxv,
                r.cpu_ul.p50,
                r.cpu_ul.p99,
                r.cpu_ul.maxv,
                gdl_r,
                gul_r,
                cdl_r,
                cul_r,
                cores,
                frac_dl,
                frac_ul,
                r.pass ? "PASS" : "FAIL");
    csv << r.ports << ',' << r.layers << ',' << r.gpu_dl.p50 << ',' << r.gpu_dl.p99 << ',' << r.gpu_dl.maxv << ','
        << r.gpu_ul.p50 << ',' << r.gpu_ul.p99 << ',' << r.gpu_ul.maxv << ',' << r.cpu_dl.p50 << ',' << r.cpu_dl.p99
        << ',' << r.cpu_dl.maxv << ',' << r.cpu_ul.p50 << ',' << r.cpu_ul.p99 << ',' << r.cpu_ul.maxv << ','
        << r.gpu_precode.p50 << ',' << r.cpu_precode.p50 << ',' << r.ocudu_prg_precode.p50 << ',' << r.precode_flops
        << ',' << gdl_r << ',' << gul_r << ',' << cdl_r << ',' << cul_r << ',' << cores << ',' << frac_dl << ','
        << frac_ul << ',' << '"' << r.cpu_precode_impl << '"' << ',' << r.precode_mismatches << ','
        << r.combine_mismatches << ',' << r.precode_max_err << ',' << r.combine_max_err << ','
        << r.opt_vs_ref_max_err << ',' << (r.pass ? 1 : 0) << '\n';
  }
  csv.close();

  std::printf("\nThresholds:\n");
  if (cpu_miss_ports > 0) {
    std::printf("- (a) One CPU core misses p99 (DL p99, UL p99, or DL+UL p99 > 0.5 ms): first at %d ports\n",
                cpu_miss_ports);
  } else {
    std::printf("- (a) One CPU core never misses p99 within tested port counts\n");
  }
  if (gpu_half_ports > 0) {
    std::printf("- (b) GPU exceeds 50%% of the 0.5 ms slot (DL or UL p50 > 0.25 ms): first at %d ports\n",
                gpu_half_ports);
  } else {
    std::printf("- (b) GPU never exceeds 50%% of the slot (by p50) within tested port counts\n");
  }
  if (!stop_reason.empty()) {
    std::printf("- Stopped early: %s\n", stop_reason.c_str());
  } else {
    std::printf("- Ran all requested port counts (2..64); memory ~O(100 MB) at 64 ports — still meaningful\n");
  }
  std::printf("\nCSV written to %s\n", csv_path);

  bool all_pass = true;
  for (const auto& r : results) {
    if (!r.stopped_early && !r.pass) {
      all_pass = false;
    }
  }
  return all_pass ? 0 : 1;
}
