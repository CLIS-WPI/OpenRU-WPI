// SPDX-FileCopyrightText: Copyright (C) 2026 Software Radio Systems Limited
// SPDX-License-Identifier: BSD-3-Clause-Open-MPI
//
// Scaling study: CPU cores needed vs antenna ports at 100 MHz / 30 kHz SCS,
// with Category-B precoding (layers → ports) and UL combining.

#include "lowphy_cuda.h"
#include "lowphy_pipeline.h"
#include "lowphy_precoding.h"

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


/// Category-B precoding. Ports ≤ 4: OCUDU `channel_precoder` (avx512).
/// Ports > 4: labeled reference matching OCUDU generic math
/// (`channel_precoder_generic.cpp:9-30`); OCUDU caps ports at
/// `precoding_constants::MAX_NOF_PORTS` (`precoding_constants.h:24`).
void cpu_precode_catb(std::vector<ocudu::cbf16_t>&       out_ports,
                      const std::vector<ocudu::cbf16_t>& in_layers,
                      const std::vector<ocudu::cf_t>&    weights,
                      unsigned                           nof_layers,
                      unsigned                           nof_ports,
                      unsigned                           nof_prbs,
                      ocudu::channel_precoder*           ocudu_precoder)
{
  const unsigned nof_subc = nof_prbs * 12u;
  out_ports.assign(static_cast<size_t>(nof_ports) * NOF_SYMBOLS_PER_SLOT * nof_subc, ocudu::cbf16_t(0.0f, 0.0f));

  const bool use_ocudu = (ocudu_precoder != nullptr) &&
                         (nof_ports <= ocudu::precoding_constants::MAX_NOF_PORTS) &&
                         (nof_layers <= ocudu::precoding_constants::MAX_NOF_LAYERS);

  if (use_ocudu) {
    ocudu::dynamic_re_buffer<ocudu::cf_t>    in_buf(nof_layers, 12);
    ocudu::dynamic_re_buffer<ocudu::cbf16_t> out_buf(nof_ports, 12);
    in_buf.resize(nof_layers, 12);
    out_buf.resize(nof_ports, 12);
    for (unsigned symbol = 0; symbol != NOF_SYMBOLS_PER_SLOT; ++symbol) {
      for (unsigned prb = 0; prb != nof_prbs; ++prb) {
        ocudu::precoding_weight_matrix mat(nof_layers, nof_ports);
        for (unsigned port = 0; port != nof_ports; ++port) {
          for (unsigned layer = 0; layer != nof_layers; ++layer) {
            mat.set_coefficient(weights[(static_cast<size_t>(prb) * nof_ports + port) * nof_layers + layer],
                                layer,
                                port);
          }
        }
        for (unsigned layer = 0; layer != nof_layers; ++layer) {
          auto slice = in_buf.get_slice(layer);
          for (unsigned k = 0; k != 12; ++k) {
            slice[k] = ocudu::to_cf(
                in_layers[(static_cast<size_t>(layer) * NOF_SYMBOLS_PER_SLOT + symbol) * nof_subc + prb * 12 + k]);
          }
        }
        ocudu_precoder->apply_precoding(out_buf, in_buf, mat);
        for (unsigned port = 0; port != nof_ports; ++port) {
          auto slice = out_buf.get_slice(port);
          for (unsigned k = 0; k != 12; ++k) {
            out_ports[(static_cast<size_t>(port) * NOF_SYMBOLS_PER_SLOT + symbol) * nof_subc + prb * 12 + k] = slice[k];
          }
        }
      }
    }
    return;
  }

  // Labeled reference (OCUDU-generic math, unbounded ports).
  for (unsigned symbol = 0; symbol != NOF_SYMBOLS_PER_SLOT; ++symbol) {
    for (unsigned port = 0; port != nof_ports; ++port) {
      for (unsigned re = 0; re != nof_subc; ++re) {
        const unsigned prb = re / 12u;
        ocudu::cf_t    sum = ocudu::cf_t(0.0f, 0.0f);
        for (unsigned layer = 0; layer != nof_layers; ++layer) {
          const ocudu::cf_t in = ocudu::to_cf(
              in_layers[(static_cast<size_t>(layer) * NOF_SYMBOLS_PER_SLOT + symbol) * nof_subc + re]);
          const ocudu::cf_t w =
              weights[(static_cast<size_t>(prb) * nof_ports + port) * nof_layers + layer];
          sum += in * w;
        }
        out_ports[(static_cast<size_t>(port) * NOF_SYMBOLS_PER_SLOT + symbol) * nof_subc + re] = ocudu::cbf16_t(sum);
      }
    }
  }
}

void cpu_combine_catb(std::vector<ocudu::cbf16_t>&     out_layers,
                      const std::vector<ocudu::cf_t>&  in_ports,
                      const std::vector<ocudu::cf_t>&  weights,
                      unsigned                         nof_layers,
                      unsigned                         nof_ports,
                      unsigned                         nof_prbs)
{
  const unsigned nof_subc = nof_prbs * 12u;
  out_layers.assign(static_cast<size_t>(nof_layers) * NOF_SYMBOLS_PER_SLOT * nof_subc, ocudu::cbf16_t(0.0f, 0.0f));
  for (unsigned symbol = 0; symbol != NOF_SYMBOLS_PER_SLOT; ++symbol) {
    for (unsigned layer = 0; layer != nof_layers; ++layer) {
      for (unsigned re = 0; re != nof_subc; ++re) {
        const unsigned prb = re / 12u;
        ocudu::cf_t    sum = ocudu::cf_t(0.0f, 0.0f);
        for (unsigned port = 0; port != nof_ports; ++port) {
          const ocudu::cf_t y =
              in_ports[(static_cast<size_t>(port) * NOF_SYMBOLS_PER_SLOT + symbol) * nof_subc + re];
          const ocudu::cf_t w =
              weights[(static_cast<size_t>(prb) * nof_ports + port) * nof_layers + layer];
          sum += y * std::conj(w);
        }
        out_layers[(static_cast<size_t>(layer) * NOF_SYMBOLS_PER_SLOT + symbol) * nof_subc + re] = ocudu::cbf16_t(sum);
      }
    }
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

struct row_result {
  unsigned ports = 0, layers = 0;
  latency_stats gpu_dl, gpu_ul, cpu_dl, cpu_ul;
  size_t   precode_mismatches = 0;
  size_t   combine_mismatches = 0;
  int      precode_max_lsb    = 0;
  int      combine_max_lsb    = 0;
  bool     pass               = false;
  const char* cpu_precode_impl = "";
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
  std::printf("OCUDU precoder: %s (MAX_NOF_PORTS=%u in precoding_constants.h:24; "
              "apply_precoding in channel_precoder_impl.cpp:9-51; "
              "generic math channel_precoder_generic.cpp:9-30)\n",
              ocudu_precoder ? "avx512 available for ports<=4" : "unavailable",
              ocudu::precoding_constants::MAX_NOF_PORTS);
  std::printf("GPU precoding: custom CUDA kernel (Cat-B per-PRB); Jetson not claimed\n\n");

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
      row.cpu_precode_impl =
          (ports <= ocudu::precoding_constants::MAX_NOF_PORTS) ? "OCUDU avx512" : "reference (OCUDU-generic math)";

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

      lowphy_catb_precode(d_layer_cbf16, d_weights, d_port_cbf16, layers, ports, NOF_SYMBOLS_PER_SLOT, nof_prbs, stream);
      std::vector<ocudu::cbf16_t> gpu_ported(port_grid_elems);
      CUDA_CHECK(cudaMemcpyAsync(gpu_ported.data(), d_port_cbf16, port_grid_elems * sizeof(ocudu::cbf16_t),
                                 cudaMemcpyDeviceToHost, stream));
      CUDA_CHECK(cudaStreamSynchronize(stream));

      // Correctness vs reference in float domain (bf16 bit-diff is misleading across exponents).
      // Pass if max |gpu-cpu| <= 2^-6 (~bf16 eps) after to_float.
      std::vector<ocudu::cbf16_t> cpu_ported;
      cpu_precode_catb(cpu_ported, layer_grid, weights, layers, ports, nof_prbs, nullptr);
      double precode_max_err = 0.0;
      for (size_t i = 0; i != port_grid_elems; ++i) {
        const ocudu::cf_t g = ocudu::to_cf(gpu_ported[i]);
        const ocudu::cf_t c = ocudu::to_cf(cpu_ported[i]);
        const double err = std::hypot(static_cast<double>(g.real() - c.real()),
                                      static_cast<double>(g.imag() - c.imag()));
        if (err > 1e-5) {
          ++row.precode_mismatches;
        }
        precode_max_err = std::max(precode_max_err, err);
      }
      row.precode_max_lsb = static_cast<int>(std::ceil(precode_max_err * 32767.0)); // report as ci16-LSB scale

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

      // Combine correctness: run combine on CPU from GPU demod cf32 dump once.
      {
        std::vector<ocudu::cf_t> port_cf(port_grid_elems);
        CUDA_CHECK(cudaMemcpy(port_cf.data(), d_port_cf32, port_grid_elems * sizeof(lowphy_cf32), cudaMemcpyDeviceToHost));
        // Reinterpret lowphy_cf32 as cf_t (same layout).
        std::vector<ocudu::cbf16_t> cpu_combined;
        cpu_combine_catb(cpu_combined, port_cf, weights, layers, ports, nof_prbs);
        std::vector<ocudu::cbf16_t> gpu_combined(layer_grid_elems);
        lowphy_catb_combine(
            d_port_cf32, d_weights, d_layer_cbf16, layers, ports, NOF_SYMBOLS_PER_SLOT, nof_prbs, stream);
        CUDA_CHECK(cudaMemcpy(gpu_combined.data(), d_layer_cbf16, layer_grid_elems * sizeof(ocudu::cbf16_t),
                              cudaMemcpyDeviceToHost));
        CUDA_CHECK(cudaStreamSynchronize(stream));
        double combine_max_err = 0.0;
        for (size_t i = 0; i != layer_grid_elems; ++i) {
          const ocudu::cf_t g = ocudu::to_cf(gpu_combined[i]);
          const ocudu::cf_t c = ocudu::to_cf(cpu_combined[i]);
          const double err = std::hypot(static_cast<double>(g.real() - c.real()),
                                        static_cast<double>(g.imag() - c.imag()));
          if (err > 1e-5) {
            ++row.combine_mismatches;
          }
          combine_max_err = std::max(combine_max_err, err);
        }
        row.combine_max_lsb = static_cast<int>(std::ceil(combine_max_err * 32767.0));
      }

      // ---- CPU DL/UL timing (FFTW + AVX-512 BFP + precoder) ----
      std::vector<ocudu::cbf16_t> dec_layers(layer_grid_elems);
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
        cpu_precode_catb(precoded, dec_layers, weights, layers, ports, nof_prbs, ocudu_precoder.get());
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
        cpu_combine_catb(combined, demod_grid, weights, layers, ports, nof_prbs);
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

      // ~1 bf16 ULP at unit scale is ~0.0078; allow 1e-3 absolute after to_float.
      row.pass = (row.precode_max_lsb <= static_cast<int>(std::ceil(1e-3 * 32767.0))) &&
                 (row.combine_max_lsb <= static_cast<int>(std::ceil(1e-3 * 32767.0)));
      results.push_back(row);

      std::printf("ports=%u layers=%u  GPU DL p50/p99=%.4f/%.4f  UL=%.4f/%.4f  "
                  "CPU DL=%.4f/%.4f UL=%.4f/%.4f  precode_mis=%zu(maxLSB=%d) combine_mis=%zu(maxLSB=%d) [%s]  impl=%s\n",
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
                  row.precode_max_lsb,
                  row.combine_mismatches,
                  row.combine_max_lsb,
                  row.pass ? "PASS" : "FAIL",
                  row.cpu_precode_impl);

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
         "gpu_dl_p99_p50,gpu_ul_p99_p50,cpu_dl_p99_p50,cpu_ul_p99_p50,"
         "cores_needed_dl_ul,gpu_frac_slot_dl,gpu_frac_slot_ul,cpu_precode_impl,precode_mismatches,"
         "combine_mismatches,pass\n";

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
        << ',' << r.cpu_dl.maxv << ',' << r.cpu_ul.p50 << ',' << r.cpu_ul.p99 << ',' << r.cpu_ul.maxv << ',' << gdl_r
        << ',' << gul_r << ',' << cdl_r << ',' << cul_r << ',' << cores << ',' << frac_dl << ',' << frac_ul << ','
        << '"' << r.cpu_precode_impl << '"' << ',' << r.precode_mismatches << ',' << r.combine_mismatches << ','
        << (r.pass ? 1 : 0) << '\n';
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
