// SPDX-FileCopyrightText: Copyright (C) 2026 Software Radio Systems Limited
// SPDX-License-Identifier: BSD-3-Clause-Open-MPI

#include "lowphy_cuda.h"
#include "lowphy_pipeline.h"

#include "iq_compression_bfp_avx2.h"
#include "phase_compensation_lut.h"

#include "ocudu/adt/bf16.h"
#include "ocudu/adt/complex.h"
#include "ocudu/ocuduvec/conversion.h"
#include "ocudu/ocudulog/ocudulog.h"
#include "ocudu/ofh/compression/compression_params.h"
#include "ocudu/phy/generic_functions/generic_functions_factories.h"
#include "ocudu/phy/lower/modulation/modulation_factories.h"
#include "ocudu/phy/lower/modulation/ofdm_demodulator.h"
#include "ocudu/phy/lower/modulation/ofdm_modulator.h"
#include "ocudu/phy/lower/sampling_rate.h"
#include "ocudu/phy/support/resource_grid.h"
#include "ocudu/phy/support/resource_grid_reader.h"
#include "ocudu/phy/support/resource_grid_writer.h"
#include "ocudu/phy/support/support_factories.h"
#include "ocudu/ran/cyclic_prefix.h"
#include "ocudu/ran/phy_time_unit.h"
#include "ocudu/ran/resource_block.h"
#include "ocudu/ran/slot_point.h"
#include "ocudu/ran/subcarrier_spacing.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <random>
#include <sched.h>
#include <string>
#include <utility>
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
constexpr unsigned SUSTAINED_SLOTS      = 4000;
constexpr unsigned LATENCY_ITERS        = 200;
constexpr unsigned CPU_CORE             = 8;
constexpr unsigned WARMUP               = 5;

struct profile {
  const char* name;
  unsigned    bw_rb;
  unsigned    srate_Hz;
};

struct capture_writer : public ocudu::resource_grid_writer {
  unsigned                  nof_ports;
  unsigned                  nof_symbols;
  unsigned                  nof_subc;
  std::vector<ocudu::cf_t>& output;

  capture_writer(unsigned nof_ports_, unsigned nof_symbols_, unsigned nof_subc_, std::vector<ocudu::cf_t>& output_) :
    nof_ports(nof_ports_), nof_symbols(nof_symbols_), nof_subc(nof_subc_), output(output_)
  {
  }

  unsigned get_nof_ports() const override { return nof_ports; }
  unsigned get_nof_subc() const override { return nof_subc; }
  unsigned get_nof_symbols() const override { return nof_symbols; }

  ocudu::span<const ocudu::cf_t>
  put(unsigned                                                      port,
      unsigned                                                      l,
      unsigned                                                      k_init,
      const ocudu::bounded_bitset<ocudu::MAX_NOF_SUBCARRIERS>& mask,
      ocudu::span<const ocudu::cf_t> symbols) override
  {
    unsigned count = mask.count();
    unsigned index = 0;
    for (unsigned k = 0; (k != mask.size()) && (index != count); ++k) {
      if (mask.test(k)) {
        output[((port * nof_symbols + l) * nof_subc) + k_init + k] = symbols[index++];
      }
    }
    return symbols.last(symbols.size() - count);
  }

  ocudu::span<const ocudu::cbf16_t>
  put(unsigned                                                      port,
      unsigned                                                      l,
      unsigned                                                      k_init,
      const ocudu::bounded_bitset<ocudu::MAX_NOF_SUBCARRIERS>& mask,
      ocudu::span<const ocudu::cbf16_t> symbols) override
  {
    unsigned count = mask.count();
    unsigned index = 0;
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

  ocudu::span<ocudu::cbf16_t> get_view(unsigned /*port*/, unsigned /*l*/) override { return {}; }
};

struct latency_stats {
  double p50_ms  = 0.0;
  double p99_ms  = 0.0;
  double max_ms  = 0.0;
  double mean_ms = 0.0;
};

latency_stats compute_stats(std::vector<double> samples_ms)
{
  latency_stats stats;
  if (samples_ms.empty()) {
    return stats;
  }
  std::sort(samples_ms.begin(), samples_ms.end());
  const size_t n = samples_ms.size();
  stats.p50_ms   = samples_ms[(n * 50) / 100];
  stats.p99_ms   = samples_ms[std::min(n - 1, (n * 99) / 100)];
  stats.max_ms   = samples_ms.back();
  double sum     = 0.0;
  for (double v : samples_ms) {
    sum += v;
  }
  stats.mean_ms = sum / static_cast<double>(n);
  return stats;
}

void fill_random_grid(std::vector<ocudu::cbf16_t>& grid, float scale, uint32_t seed)
{
  std::mt19937                          generator(seed);
  std::uniform_real_distribution<float> distribution(-scale, scale);
  for (ocudu::cbf16_t& value : grid) {
    value = ocudu::cbf16_t(distribution(generator), distribution(generator));
  }
}

bool pin_cpu(unsigned core)
{
  cpu_set_t set;
  CPU_ZERO(&set);
  CPU_SET(core, &set);
  return sched_setaffinity(0, sizeof(set), &set) == 0;
}

struct case_result {
  std::string   profile_name;
  unsigned      dft_size = 0;
  unsigned      ports    = 0;
  size_t        dl_mismatches = 0;
  size_t        ul_mismatches = 0;
  latency_stats gpu_dl_lat;
  latency_stats gpu_ul_lat;
  latency_stats gpu_dl_sustained;
  latency_stats gpu_ul_sustained;
  double        gpu_dl_sustained_ms_per_slot = 0.0;
  double        gpu_ul_sustained_ms_per_slot = 0.0;
  latency_stats cpu_dl;
  latency_stats cpu_ul;
  bool          pass = false;
};

} // namespace

int main(int argc, char** argv)
{
  unsigned sustained_slots = SUSTAINED_SLOTS;
  unsigned latency_iters   = LATENCY_ITERS;
  unsigned cpu_core        = CPU_CORE;
  for (int i = 1; i < argc; ++i) {
    if ((std::strcmp(argv[i], "--sustained") == 0) && (i + 1 < argc)) {
      sustained_slots = static_cast<unsigned>(std::strtoul(argv[++i], nullptr, 10));
    } else if ((std::strcmp(argv[i], "--latency-iters") == 0) && (i + 1 < argc)) {
      latency_iters = static_cast<unsigned>(std::strtoul(argv[++i], nullptr, 10));
    } else if ((std::strcmp(argv[i], "--cpu-core") == 0) && (i + 1 < argc)) {
      cpu_core = static_cast<unsigned>(std::strtoul(argv[++i], nullptr, 10));
    }
  }

  if (cpu_core > 15) {
    std::fprintf(stderr, "CPU core must be in 0-15 (got %u).\n", cpu_core);
    return 1;
  }

  ocudulog::init();
  auto& logger = ocudulog::fetch_basic_logger("pipeline_test");
  logger.set_level(ocudulog::basic_levels::warning);

  CUDA_CHECK(cudaSetDevice(0));
  cudaDeviceProp device_prop;
  CUDA_CHECK(cudaGetDeviceProperties(&device_prop, 0));

  std::printf("# Device-resident low-PHY pipeline (compute-only)\n\n");
  std::printf("Device: %s (compute capability %d.%d)\n", device_prop.name, device_prop.major, device_prop.minor);
  std::printf("CPU pin: core %u (0-15), AVX2 Release OCUDU path, BFP width %u\n", cpu_core, DATA_WIDTH);
  std::printf("Sustained slots: %u; latency iters: %u\n\n", sustained_slots, latency_iters);

  const std::vector<profile> profiles = {
      {"20 MHz", 51, 23040000u},
      {"40 MHz", 106, 46080000u},
      {"100 MHz", 273, 122880000u},
  };
  const std::vector<unsigned> port_counts = {2, 4};

  std::vector<case_result> results;
  bool                     all_pass = true;

  for (const profile& profile : profiles) {
    const ocudu::subcarrier_spacing scs            = ocudu::subcarrier_spacing::kHz30;
    const ocudu::cyclic_prefix      cp             = ocudu::cyclic_prefix::NORMAL;
    const unsigned                  numerology     = ocudu::to_numerology_value(scs);
    const unsigned                  nof_slots_sf   = ocudu::get_nof_slots_per_subframe(scs);
    const unsigned                  nof_symbols_sf = nof_slots_sf * NOF_SYMBOLS_PER_SLOT;
    const ocudu::sampling_rate      srate          = ocudu::sampling_rate::from_Hz(profile.srate_Hz);

    if (!srate.is_valid(scs)) {
      std::fprintf(stderr, "Invalid sampling rate for %s\n", profile.name);
      return 1;
    }

    const unsigned dft_size         = srate.get_dft_size(scs);
    const double   sampling_rate_Hz = static_cast<double>(srate.to_Hz());
    const unsigned rg_size          = profile.bw_rb * ocudu::NOF_SUBCARRIERS_PER_RB;
    const unsigned nof_prbs         = profile.bw_rb;
    const unsigned prb_size         = 1 + ((24 * DATA_WIDTH + 7) / 8);
    const float    mod_scale        = 1.0f;
    const float    demod_scale =
        1.0f / static_cast<float>(std::sqrt(static_cast<double>(profile.bw_rb * ocudu::NOF_SUBCARRIERS_PER_RB)));

    std::vector<unsigned> cp_len(nof_symbols_sf);
    std::vector<unsigned> symbol_start(nof_symbols_sf);
    unsigned              sample_offset = 0;
    for (unsigned symbol = 0; symbol != nof_symbols_sf; ++symbol) {
      cp_len[symbol]       = cp.get_length(symbol, scs).to_samples(sampling_rate_Hz);
      symbol_start[symbol] = sample_offset;
      sample_offset += cp_len[symbol] + dft_size;
    }

    ocudu::phase_compensation_lut mod_phase(scs, cp, dft_size, CENTER_FREQ_HZ, true);
    ocudu::phase_compensation_lut demod_phase(scs, cp, dft_size, CENTER_FREQ_HZ, false);
    std::vector<lowphy_cf32>      phase_mod(nof_symbols_sf);
    std::vector<lowphy_cf32>      phase_demod(nof_symbols_sf);
    for (unsigned symbol = 0; symbol != nof_symbols_sf; ++symbol) {
      ocudu::cf_t coefficient = mod_phase.get_coefficient(symbol);
      phase_mod[symbol]       = {coefficient.real(), coefficient.imag()};
      coefficient             = demod_phase.get_coefficient(symbol);
      phase_demod[symbol]     = {coefficient.real(), coefficient.imag()};
    }

    auto                                      dft_factory = ocudu::create_dft_processor_factory_generic();
    ocudu::ofdm_factory_generic_configuration ofdm_config{dft_factory};
    auto mod_factory   = ocudu::create_ofdm_modulator_factory_generic(ofdm_config);
    auto demod_factory = ocudu::create_ofdm_demodulator_factory_generic(ofdm_config);

    ocudu::ofdm_modulator_configuration modulator_config = {
        .numerology     = numerology,
        .bw_rb          = profile.bw_rb,
        .dft_size       = dft_size,
        .cp             = cp,
        .scale          = mod_scale,
        .center_freq_Hz = CENTER_FREQ_HZ,
    };
    ocudu::ofdm_demodulator_configuration demodulator_config = {
        .numerology                = numerology,
        .bw_rb                     = profile.bw_rb,
        .dft_size                  = dft_size,
        .cp                        = cp,
        .nof_samples_window_offset = 0,
        .scale                     = demod_scale,
        .center_freq_Hz            = CENTER_FREQ_HZ,
    };

    auto slot_modulator   = mod_factory->create_ofdm_slot_modulator(modulator_config);
    auto slot_demodulator = demod_factory->create_ofdm_slot_demodulator(demodulator_config);
    const unsigned slot_index   = 0;
    const unsigned slot_start   = symbol_start[0];
    const unsigned slot_samples = slot_modulator->get_slot_size(slot_index);

    std::printf("Profile %s: DFT %u, BW %u PRB, slot_samples %u\n",
                profile.name,
                dft_size,
                profile.bw_rb,
                slot_samples);

    for (unsigned ports : port_counts) {
      case_result current;
      current.profile_name = profile.name;
      current.dft_size     = dft_size;
      current.ports        = ports;

      const size_t grid_elems  = static_cast<size_t>(ports) * NOF_SYMBOLS_PER_SLOT * rg_size;
      const size_t comp_bytes  = static_cast<size_t>(ports) * NOF_SYMBOLS_PER_SLOT * nof_prbs * prb_size;
      const size_t ci16_bytes  = static_cast<size_t>(ports) * slot_samples * sizeof(int16_t) * 2u;
      const size_t cbf16_bytes = grid_elems * sizeof(ocudu::cbf16_t);

      std::vector<ocudu::cbf16_t> grid_src(grid_elems);
      fill_random_grid(grid_src, GRID_SCALE, 0xA11Cu + dft_size * 16u + ports);

      auto grid_factory = ocudu::create_resource_grid_factory();

      ocudu::ofh::ru_compression_params   params{ocudu::ofh::compression_type::BFP, DATA_WIDTH};
      ocudu::ofh::iq_compression_bfp_avx2 bfp_avx2(logger, 1.0f);

      std::vector<uint8_t> host_compressed_src(comp_bytes);
      for (unsigned port = 0; port != ports; ++port) {
        for (unsigned symbol = 0; symbol != NOF_SYMBOLS_PER_SLOT; ++symbol) {
          size_t grid_offset = (static_cast<size_t>(port) * NOF_SYMBOLS_PER_SLOT + symbol) * rg_size;
          size_t comp_offset = (static_cast<size_t>(port) * NOF_SYMBOLS_PER_SLOT + symbol) * nof_prbs * prb_size;
          bfp_avx2.compress(ocudu::span<uint8_t>(host_compressed_src.data() + comp_offset, nof_prbs * prb_size),
                            ocudu::span<const ocudu::cbf16_t>(grid_src.data() + grid_offset, rg_size),
                            params);
        }
      }

      // CPU DL reference: BFP decompress + OFDM modulate → ci16.
      std::vector<ocudu::cbf16_t> cpu_decompressed(grid_elems);
      for (unsigned port = 0; port != ports; ++port) {
        for (unsigned symbol = 0; symbol != NOF_SYMBOLS_PER_SLOT; ++symbol) {
          size_t grid_offset = (static_cast<size_t>(port) * NOF_SYMBOLS_PER_SLOT + symbol) * rg_size;
          size_t comp_offset = (static_cast<size_t>(port) * NOF_SYMBOLS_PER_SLOT + symbol) * nof_prbs * prb_size;
          bfp_avx2.decompress(ocudu::span<ocudu::cbf16_t>(cpu_decompressed.data() + grid_offset, rg_size),
                              ocudu::span<const uint8_t>(host_compressed_src.data() + comp_offset, nof_prbs * prb_size),
                              params);
        }
      }
      auto cpu_grid = grid_factory->create(ports, NOF_SYMBOLS_PER_SLOT, rg_size);
      for (unsigned port = 0; port != ports; ++port) {
        for (unsigned symbol = 0; symbol != NOF_SYMBOLS_PER_SLOT; ++symbol) {
          auto view = cpu_grid->get_writer().get_view(port, symbol);
          std::copy_n(cpu_decompressed.data() + (static_cast<size_t>(port) * NOF_SYMBOLS_PER_SLOT + symbol) * rg_size,
                      rg_size,
                      view.begin());
        }
      }

      std::vector<ocudu::ci16_t> cpu_ci16(static_cast<size_t>(ports) * slot_samples);
      {
        std::vector<ocudu::cf_t> cpu_slot_cf(slot_samples);
        for (unsigned port = 0; port != ports; ++port) {
          slot_modulator->modulate(ocudu::span<ocudu::cf_t>(cpu_slot_cf), cpu_grid->get_reader(), port, slot_index);
          ocudu::ocuduvec::convert(ocudu::span<ocudu::ci16_t>(cpu_ci16.data() + port * slot_samples, slot_samples),
                                   ocudu::span<const ocudu::cf_t>(cpu_slot_cf),
                                   32767.0f);
        }
      }

      // Host buffers (preallocated, then pinned with cudaHostRegister).
      std::vector<uint8_t> h_comp_a(comp_bytes), h_comp_b(comp_bytes);
      std::vector<uint8_t> h_comp_out_a(comp_bytes), h_comp_out_b(comp_bytes);
      std::vector<int16_t> h_ci16_a(ci16_bytes / sizeof(int16_t)), h_ci16_b(ci16_bytes / sizeof(int16_t));
      std::vector<int16_t> h_ci16_in_a(ci16_bytes / sizeof(int16_t)), h_ci16_in_b(ci16_bytes / sizeof(int16_t));

      std::memcpy(h_comp_a.data(), host_compressed_src.data(), comp_bytes);
      std::memcpy(h_comp_b.data(), host_compressed_src.data(), comp_bytes);
      std::memcpy(h_ci16_in_a.data(), cpu_ci16.data(), ci16_bytes);
      std::memcpy(h_ci16_in_b.data(), cpu_ci16.data(), ci16_bytes);

      auto register_buf = [](void* ptr, size_t bytes) {
        CUDA_CHECK(cudaHostRegister(ptr, bytes, cudaHostRegisterDefault));
      };
      register_buf(h_comp_a.data(), comp_bytes);
      register_buf(h_comp_b.data(), comp_bytes);
      register_buf(h_comp_out_a.data(), comp_bytes);
      register_buf(h_comp_out_b.data(), comp_bytes);
      register_buf(h_ci16_a.data(), ci16_bytes);
      register_buf(h_ci16_b.data(), ci16_bytes);
      register_buf(h_ci16_in_a.data(), ci16_bytes);
      register_buf(h_ci16_in_b.data(), ci16_bytes);

      lowphy_pipeline pipe{};
      if (!lowphy_pipeline_create(&pipe,
                                  ports,
                                  nof_prbs,
                                  dft_size,
                                  profile.bw_rb,
                                  slot_samples,
                                  DATA_WIDTH,
                                  nof_symbols_sf,
                                  phase_mod.data(),
                                  phase_demod.data(),
                                  cp_len.data(),
                                  symbol_start.data())) {
        std::fprintf(stderr, "pipeline create failed for %s %u ports\n", profile.name, ports);
        return 1;
      }

      cudaStream_t stream0 = nullptr;
      cudaStream_t stream1 = nullptr;
      CUDA_CHECK(cudaStreamCreate(&stream0));
      CUDA_CHECK(cudaStreamCreate(&stream1));

      // ---- Correctness: pipeline vs standalone kernel sequence ----
      {
        std::vector<int16_t> pipe_dl(ci16_bytes / sizeof(int16_t));
        std::vector<int16_t> ref_dl(ci16_bytes / sizeof(int16_t));
        CUDA_CHECK(cudaHostRegister(pipe_dl.data(), ci16_bytes, cudaHostRegisterDefault));
        CUDA_CHECK(cudaHostRegister(ref_dl.data(), ci16_bytes, cudaHostRegisterDefault));

        lowphy_pipeline_dl(&pipe, 0, slot_index, slot_start, h_comp_a.data(), pipe_dl.data(), stream0);
        CUDA_CHECK(cudaStreamSynchronize(stream0));

        uint8_t*     d_comp  = nullptr;
        uint16_t*    d_cbf16 = nullptr;
        int16_t*     d_ci16  = nullptr;
        uint8_t*     d_empty = nullptr;
        lowphy_cf32* d_phase = nullptr;
        unsigned*    d_cp    = nullptr;
        unsigned*    d_ss    = nullptr;
        CUDA_CHECK(cudaMalloc(&d_comp, comp_bytes + 2));
        CUDA_CHECK(cudaMemset(d_comp, 0, comp_bytes + 2));
        CUDA_CHECK(cudaMalloc(reinterpret_cast<void**>(&d_cbf16), cbf16_bytes));
        CUDA_CHECK(cudaMalloc(reinterpret_cast<void**>(&d_ci16), ci16_bytes));
        CUDA_CHECK(cudaMalloc(&d_empty, ports));
        CUDA_CHECK(cudaMemset(d_empty, 0, ports));
        CUDA_CHECK(cudaMalloc(&d_phase, nof_symbols_sf * sizeof(lowphy_cf32)));
        CUDA_CHECK(cudaMalloc(&d_cp, nof_symbols_sf * sizeof(unsigned)));
        CUDA_CHECK(cudaMalloc(&d_ss, nof_symbols_sf * sizeof(unsigned)));
        CUDA_CHECK(cudaMemcpy(d_comp, host_compressed_src.data(), comp_bytes, cudaMemcpyHostToDevice));
        CUDA_CHECK(cudaMemcpy(d_phase, phase_mod.data(), nof_symbols_sf * sizeof(lowphy_cf32), cudaMemcpyHostToDevice));
        CUDA_CHECK(cudaMemcpy(d_cp, cp_len.data(), nof_symbols_sf * sizeof(unsigned), cudaMemcpyHostToDevice));
        CUDA_CHECK(cudaMemcpy(d_ss, symbol_start.data(), nof_symbols_sf * sizeof(unsigned), cudaMemcpyHostToDevice));

        lowphy_ofdm_plan* mod_plan = lowphy_ofdm_plan_create(dft_size, ports, NOF_SYMBOLS_PER_SLOT, true);
        lowphy_bfp_decompress(d_comp, d_cbf16, ports, NOF_SYMBOLS_PER_SLOT, nof_prbs, DATA_WIDTH, stream0);
        lowphy_ofdm_mod_params mod{};
        mod.plan                 = mod_plan;
        mod.grid                 = d_cbf16;
        mod.out                  = d_ci16;
        mod.port_empty           = d_empty;
        mod.phase                = d_phase;
        mod.cp_len               = d_cp;
        mod.symbol_start         = d_ss;
        mod.nof_ports            = ports;
        mod.nof_symbols_per_slot = NOF_SYMBOLS_PER_SLOT;
        mod.dft_size             = dft_size;
        mod.bw_rb                = profile.bw_rb;
        mod.slot_index           = slot_index;
        mod.slot_start           = slot_start;
        mod.slot_samples         = slot_samples;
        mod.scale                = mod_scale;
        lowphy_ofdm_mod_pre(mod, stream0);
        lowphy_ofdm_mod_fft(mod, stream0);
        lowphy_ofdm_mod_post(mod, stream0);
        CUDA_CHECK(cudaMemcpyAsync(ref_dl.data(), d_ci16, ci16_bytes, cudaMemcpyDeviceToHost, stream0));
        CUDA_CHECK(cudaStreamSynchronize(stream0));

        for (size_t i = 0; i != pipe_dl.size(); ++i) {
          if (pipe_dl[i] != ref_dl[i]) {
            ++current.dl_mismatches;
          }
        }

        // UL: pipeline vs demod + cf32_to_cbf16 + compress.
        std::vector<uint8_t> pipe_ul(comp_bytes);
        std::vector<uint8_t> ref_ul(comp_bytes);
        CUDA_CHECK(cudaHostRegister(pipe_ul.data(), comp_bytes, cudaHostRegisterDefault));
        CUDA_CHECK(cudaHostRegister(ref_ul.data(), comp_bytes, cudaHostRegisterDefault));

        lowphy_pipeline_ul(&pipe, 0, slot_index, slot_start, h_ci16_in_a.data(), pipe_ul.data(), stream0);
        CUDA_CHECK(cudaStreamSynchronize(stream0));

        lowphy_cf32* d_cf32 = nullptr;
        CUDA_CHECK(cudaMalloc(reinterpret_cast<void**>(&d_cf32), grid_elems * sizeof(lowphy_cf32)));
        lowphy_ofdm_plan* demod_plan = lowphy_ofdm_plan_create(dft_size, ports, NOF_SYMBOLS_PER_SLOT, false);
        CUDA_CHECK(cudaMemcpy(d_ci16, h_ci16_in_a.data(), ci16_bytes, cudaMemcpyHostToDevice));
        CUDA_CHECK(cudaMemcpy(d_phase, phase_demod.data(), nof_symbols_sf * sizeof(lowphy_cf32), cudaMemcpyHostToDevice));

        lowphy_ofdm_demod_params demod{};
        demod.plan                 = demod_plan;
        demod.in                   = d_ci16;
        demod.grid                 = d_cf32;
        demod.phase                = d_phase;
        demod.window_phase         = nullptr;
        demod.cp_len               = d_cp;
        demod.symbol_start         = d_ss;
        demod.nof_ports            = ports;
        demod.nof_symbols_per_slot = NOF_SYMBOLS_PER_SLOT;
        demod.dft_size             = dft_size;
        demod.bw_rb                = profile.bw_rb;
        demod.slot_index           = slot_index;
        demod.slot_start           = slot_start;
        demod.slot_samples         = slot_samples;
        demod.window_offset        = 0;
        demod.scale                = demod_scale;
        lowphy_ofdm_demod_pre(demod, stream0);
        lowphy_ofdm_demod_fft(demod, stream0);
        lowphy_ofdm_demod_post(demod, stream0);
        lowphy_cf32_to_cbf16(d_cf32, d_cbf16, static_cast<unsigned>(grid_elems), stream0);
        lowphy_bfp_compress(d_cbf16, d_comp, ports, NOF_SYMBOLS_PER_SLOT, nof_prbs, DATA_WIDTH, stream0);
        CUDA_CHECK(cudaMemcpyAsync(ref_ul.data(), d_comp, comp_bytes, cudaMemcpyDeviceToHost, stream0));
        CUDA_CHECK(cudaStreamSynchronize(stream0));

        for (size_t i = 0; i != pipe_ul.size(); ++i) {
          if (pipe_ul[i] != ref_ul[i]) {
            ++current.ul_mismatches;
          }
        }

        lowphy_ofdm_plan_destroy(mod_plan);
        lowphy_ofdm_plan_destroy(demod_plan);
        cudaFree(d_comp);
        cudaFree(d_cbf16);
        cudaFree(d_ci16);
        cudaFree(d_empty);
        cudaFree(d_phase);
        cudaFree(d_cp);
        cudaFree(d_ss);
        cudaFree(d_cf32);
        cudaHostUnregister(pipe_dl.data());
        cudaHostUnregister(ref_dl.data());
        cudaHostUnregister(pipe_ul.data());
        cudaHostUnregister(ref_ul.data());
      }

      // ---- GPU per-slot latency (no overlap) ----
      {
        std::vector<double> dl_ms;
        std::vector<double> ul_ms;
        dl_ms.reserve(latency_iters);
        ul_ms.reserve(latency_iters);

        cudaEvent_t start_ev, stop_ev;
        CUDA_CHECK(cudaEventCreate(&start_ev));
        CUDA_CHECK(cudaEventCreate(&stop_ev));

        for (unsigned i = 0; i != WARMUP; ++i) {
          lowphy_pipeline_dl(&pipe, 0, slot_index, slot_start, h_comp_a.data(), h_ci16_a.data(), stream0);
          CUDA_CHECK(cudaStreamSynchronize(stream0));
        }
        for (unsigned i = 0; i != latency_iters; ++i) {
          CUDA_CHECK(cudaEventRecord(start_ev, stream0));
          lowphy_pipeline_dl(&pipe, 0, slot_index, slot_start, h_comp_a.data(), h_ci16_a.data(), stream0);
          CUDA_CHECK(cudaEventRecord(stop_ev, stream0));
          CUDA_CHECK(cudaEventSynchronize(stop_ev));
          float elapsed = 0.0f;
          CUDA_CHECK(cudaEventElapsedTime(&elapsed, start_ev, stop_ev));
          dl_ms.push_back(elapsed);
        }

        for (unsigned i = 0; i != WARMUP; ++i) {
          lowphy_pipeline_ul(&pipe, 0, slot_index, slot_start, h_ci16_in_a.data(), h_comp_out_a.data(), stream0);
          CUDA_CHECK(cudaStreamSynchronize(stream0));
        }
        for (unsigned i = 0; i != latency_iters; ++i) {
          CUDA_CHECK(cudaEventRecord(start_ev, stream0));
          lowphy_pipeline_ul(&pipe, 0, slot_index, slot_start, h_ci16_in_a.data(), h_comp_out_a.data(), stream0);
          CUDA_CHECK(cudaEventRecord(stop_ev, stream0));
          CUDA_CHECK(cudaEventSynchronize(stop_ev));
          float elapsed = 0.0f;
          CUDA_CHECK(cudaEventElapsedTime(&elapsed, start_ev, stop_ev));
          ul_ms.push_back(elapsed);
        }

        current.gpu_dl_lat = compute_stats(dl_ms);
        current.gpu_ul_lat = compute_stats(ul_ms);
        CUDA_CHECK(cudaEventDestroy(start_ev));
        CUDA_CHECK(cudaEventDestroy(stop_ev));
      }

      // ---- GPU sustained 4000 slots, double-buffered, 2 streams ----
      {
        auto run_sustained = [&](bool downlink) {
          std::vector<cudaEvent_t> starts(sustained_slots);
          std::vector<cudaEvent_t> stops(sustained_slots);
          for (unsigned i = 0; i != sustained_slots; ++i) {
            CUDA_CHECK(cudaEventCreate(&starts[i]));
            CUDA_CHECK(cudaEventCreate(&stops[i]));
          }

          for (unsigned i = 0; i != WARMUP; ++i) {
            cudaStream_t s = (i & 1u) ? stream1 : stream0;
            if (downlink) {
              uint8_t* hin  = (i & 1u) ? h_comp_b.data() : h_comp_a.data();
              int16_t* hout = (i & 1u) ? h_ci16_b.data() : h_ci16_a.data();
              lowphy_pipeline_dl(&pipe, i & 1u, slot_index, slot_start, hin, hout, s);
            } else {
              int16_t* hin  = (i & 1u) ? h_ci16_in_b.data() : h_ci16_in_a.data();
              uint8_t* hout = (i & 1u) ? h_comp_out_b.data() : h_comp_out_a.data();
              lowphy_pipeline_ul(&pipe, i & 1u, slot_index, slot_start, hin, hout, s);
            }
          }
          CUDA_CHECK(cudaStreamSynchronize(stream0));
          CUDA_CHECK(cudaStreamSynchronize(stream1));

          const auto wall_start = std::chrono::steady_clock::now();
          for (unsigned i = 0; i != sustained_slots; ++i) {
            cudaStream_t s = (i & 1u) ? stream1 : stream0;
            CUDA_CHECK(cudaEventRecord(starts[i], s));
            if (downlink) {
              uint8_t* hin  = (i & 1u) ? h_comp_b.data() : h_comp_a.data();
              int16_t* hout = (i & 1u) ? h_ci16_b.data() : h_ci16_a.data();
              lowphy_pipeline_dl(&pipe, i & 1u, slot_index, slot_start, hin, hout, s);
            } else {
              int16_t* hin  = (i & 1u) ? h_ci16_in_b.data() : h_ci16_in_a.data();
              uint8_t* hout = (i & 1u) ? h_comp_out_b.data() : h_comp_out_a.data();
              lowphy_pipeline_ul(&pipe, i & 1u, slot_index, slot_start, hin, hout, s);
            }
            CUDA_CHECK(cudaEventRecord(stops[i], s));
          }
          CUDA_CHECK(cudaStreamSynchronize(stream0));
          CUDA_CHECK(cudaStreamSynchronize(stream1));
          const auto wall_end = std::chrono::steady_clock::now();
          const double wall_ms =
              std::chrono::duration<double, std::milli>(wall_end - wall_start).count();

          std::vector<double> samples;
          samples.reserve(sustained_slots);
          for (unsigned i = 0; i != sustained_slots; ++i) {
            float elapsed = 0.0f;
            CUDA_CHECK(cudaEventElapsedTime(&elapsed, starts[i], stops[i]));
            samples.push_back(elapsed);
          }

          for (unsigned i = 0; i != sustained_slots; ++i) {
            CUDA_CHECK(cudaEventDestroy(starts[i]));
            CUDA_CHECK(cudaEventDestroy(stops[i]));
          }

          return std::make_pair(compute_stats(samples), wall_ms / static_cast<double>(sustained_slots));
        };

        auto dl = run_sustained(true);
        auto ul = run_sustained(false);
        current.gpu_dl_sustained            = dl.first;
        current.gpu_dl_sustained_ms_per_slot = dl.second;
        current.gpu_ul_sustained            = ul.first;
        current.gpu_ul_sustained_ms_per_slot = ul.second;
      }

      // ---- CPU OCUDU path, single thread pinned ----
      if (!pin_cpu(cpu_core)) {
        std::fprintf(stderr, "Failed to pin to CPU core %u\n", cpu_core);
        return 1;
      }

      {
        std::vector<ocudu::cbf16_t> dec_scratch(grid_elems);
        std::vector<ocudu::cf_t>    slot_cf(slot_samples);
        std::vector<ocudu::ci16_t>  out_ci16(static_cast<size_t>(ports) * slot_samples);
        auto                        timed_grid = grid_factory->create(ports, NOF_SYMBOLS_PER_SLOT, rg_size);

        auto cpu_dl_once = [&]() {
          for (unsigned port = 0; port != ports; ++port) {
            for (unsigned symbol = 0; symbol != NOF_SYMBOLS_PER_SLOT; ++symbol) {
              size_t grid_offset = (static_cast<size_t>(port) * NOF_SYMBOLS_PER_SLOT + symbol) * rg_size;
              size_t comp_offset = (static_cast<size_t>(port) * NOF_SYMBOLS_PER_SLOT + symbol) * nof_prbs * prb_size;
              bfp_avx2.decompress(ocudu::span<ocudu::cbf16_t>(dec_scratch.data() + grid_offset, rg_size),
                                  ocudu::span<const uint8_t>(host_compressed_src.data() + comp_offset, nof_prbs * prb_size),
                                  params);
            }
          }
          for (unsigned port = 0; port != ports; ++port) {
            for (unsigned symbol = 0; symbol != NOF_SYMBOLS_PER_SLOT; ++symbol) {
              auto view = timed_grid->get_writer().get_view(port, symbol);
              std::copy_n(dec_scratch.data() + (static_cast<size_t>(port) * NOF_SYMBOLS_PER_SLOT + symbol) * rg_size,
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
        cpu_dl_ms.reserve(latency_iters);
        for (unsigned i = 0; i != latency_iters; ++i) {
          const auto t0 = std::chrono::steady_clock::now();
          cpu_dl_once();
          const auto t1 = std::chrono::steady_clock::now();
          cpu_dl_ms.push_back(std::chrono::duration<double, std::milli>(t1 - t0).count());
        }
        current.cpu_dl = compute_stats(cpu_dl_ms);

        // UL CPU: OFDM demod + BFP compress. Input is CPU-modulated ci16.
        std::vector<ocudu::cf_t> cpu_demod_input(static_cast<size_t>(ports) * slot_samples);
        ocudu::ocuduvec::convert(ocudu::span<ocudu::cf_t>(cpu_demod_input),
                                 ocudu::span<const ocudu::ci16_t>(cpu_ci16),
                                 32767.0f);
        std::vector<ocudu::cf_t>    demod_grid_cf(grid_elems);
        std::vector<ocudu::cbf16_t> demod_grid_bf(grid_elems);
        std::vector<uint8_t>        ul_comp(comp_bytes);
        capture_writer              writer(ports, NOF_SYMBOLS_PER_SLOT, rg_size, demod_grid_cf);

        auto cpu_ul_once = [&]() {
          for (unsigned port = 0; port != ports; ++port) {
            slot_demodulator->demodulate(
                writer,
                ocudu::span<const ocudu::cf_t>(cpu_demod_input.data() + port * slot_samples, slot_samples),
                port,
                slot_index);
          }
          for (size_t i = 0; i != grid_elems; ++i) {
            demod_grid_bf[i] = ocudu::cbf16_t(demod_grid_cf[i]);
          }
          for (unsigned port = 0; port != ports; ++port) {
            for (unsigned symbol = 0; symbol != NOF_SYMBOLS_PER_SLOT; ++symbol) {
              size_t grid_offset = (static_cast<size_t>(port) * NOF_SYMBOLS_PER_SLOT + symbol) * rg_size;
              size_t comp_offset = (static_cast<size_t>(port) * NOF_SYMBOLS_PER_SLOT + symbol) * nof_prbs * prb_size;
              bfp_avx2.compress(ocudu::span<uint8_t>(ul_comp.data() + comp_offset, nof_prbs * prb_size),
                                ocudu::span<const ocudu::cbf16_t>(demod_grid_bf.data() + grid_offset, rg_size),
                                params);
            }
          }
        };

        for (unsigned i = 0; i != WARMUP; ++i) {
          cpu_ul_once();
        }
        std::vector<double> cpu_ul_ms;
        cpu_ul_ms.reserve(latency_iters);
        for (unsigned i = 0; i != latency_iters; ++i) {
          const auto t0 = std::chrono::steady_clock::now();
          cpu_ul_once();
          const auto t1 = std::chrono::steady_clock::now();
          cpu_ul_ms.push_back(std::chrono::duration<double, std::milli>(t1 - t0).count());
        }
        current.cpu_ul = compute_stats(cpu_ul_ms);
      }

      current.pass = (current.dl_mismatches == 0) && (current.ul_mismatches == 0);
      all_pass     = all_pass && current.pass;
      results.push_back(current);

      std::printf("  %u ports: DL mismatches=%zu UL mismatches=%zu [%s]\n",
                  ports,
                  current.dl_mismatches,
                  current.ul_mismatches,
                  current.pass ? "PASS" : "FAIL");
      std::printf("    GPU DL lat p50/p99/max = %.4f / %.4f / %.4f ms\n",
                  current.gpu_dl_lat.p50_ms,
                  current.gpu_dl_lat.p99_ms,
                  current.gpu_dl_lat.max_ms);
      std::printf("    GPU UL lat p50/p99/max = %.4f / %.4f / %.4f ms\n",
                  current.gpu_ul_lat.p50_ms,
                  current.gpu_ul_lat.p99_ms,
                  current.gpu_ul_lat.max_ms);
      std::printf("    GPU DL sustained wall=%.4f ms/slot; event p50/p99/max=%.4f/%.4f/%.4f\n",
                  current.gpu_dl_sustained_ms_per_slot,
                  current.gpu_dl_sustained.p50_ms,
                  current.gpu_dl_sustained.p99_ms,
                  current.gpu_dl_sustained.max_ms);
      std::printf("    GPU UL sustained wall=%.4f ms/slot; event p50/p99/max=%.4f/%.4f/%.4f\n",
                  current.gpu_ul_sustained_ms_per_slot,
                  current.gpu_ul_sustained.p50_ms,
                  current.gpu_ul_sustained.p99_ms,
                  current.gpu_ul_sustained.max_ms);
      std::printf("    CPU DL p50/p99/max = %.4f / %.4f / %.4f ms\n",
                  current.cpu_dl.p50_ms,
                  current.cpu_dl.p99_ms,
                  current.cpu_dl.max_ms);
      std::printf("    CPU UL p50/p99/max = %.4f / %.4f / %.4f ms\n",
                  current.cpu_ul.p50_ms,
                  current.cpu_ul.p99_ms,
                  current.cpu_ul.max_ms);

      lowphy_pipeline_destroy(&pipe);
      CUDA_CHECK(cudaStreamDestroy(stream0));
      CUDA_CHECK(cudaStreamDestroy(stream1));
      cudaHostUnregister(h_comp_a.data());
      cudaHostUnregister(h_comp_b.data());
      cudaHostUnregister(h_comp_out_a.data());
      cudaHostUnregister(h_comp_out_b.data());
      cudaHostUnregister(h_ci16_a.data());
      cudaHostUnregister(h_ci16_b.data());
      cudaHostUnregister(h_ci16_in_a.data());
      cudaHostUnregister(h_ci16_in_b.data());
    }
  }

  std::printf("\n## Correctness (pipeline vs standalone kernels)\n\n");
  std::printf("| Profile | DFT | Ports | DL mismatches | UL mismatches | Pass |\n");
  std::printf("|---|---:|---:|---:|---:|:---:|\n");
  for (const case_result& r : results) {
    std::printf("| %s | %u | %u | %zu | %zu | %s |\n",
                r.profile_name.c_str(),
                r.dft_size,
                r.ports,
                r.dl_mismatches,
                r.ul_mismatches,
                r.pass ? "PASS" : "FAIL");
  }

  std::printf("\n## GPU vs CPU per-slot latency (ms) [MEASURED] compute-only\n\n");
  std::printf("| Profile | Ports | Dir | GPU p50 | GPU p99 | GPU max | CPU p50 | CPU p99 | CPU max | Speedup (p50) |\n");
  std::printf("|---|---:|---|---:|---:|---:|---:|---:|---:|---:|\n");
  for (const case_result& r : results) {
    const double dl_sp = r.cpu_dl.p50_ms / std::max(r.gpu_dl_lat.p50_ms, 1e-9);
    const double ul_sp = r.cpu_ul.p50_ms / std::max(r.gpu_ul_lat.p50_ms, 1e-9);
    std::printf("| %s | %u | DL | %.4f | %.4f | %.4f | %.4f | %.4f | %.4f | %.2fx |\n",
                r.profile_name.c_str(),
                r.ports,
                r.gpu_dl_lat.p50_ms,
                r.gpu_dl_lat.p99_ms,
                r.gpu_dl_lat.max_ms,
                r.cpu_dl.p50_ms,
                r.cpu_dl.p99_ms,
                r.cpu_dl.max_ms,
                dl_sp);
    std::printf("| %s | %u | UL | %.4f | %.4f | %.4f | %.4f | %.4f | %.4f | %.2fx |\n",
                r.profile_name.c_str(),
                r.ports,
                r.gpu_ul_lat.p50_ms,
                r.gpu_ul_lat.p99_ms,
                r.gpu_ul_lat.max_ms,
                r.cpu_ul.p50_ms,
                r.cpu_ul.p99_ms,
                r.cpu_ul.max_ms,
                ul_sp);
  }

  std::printf("\n## GPU sustained throughput (%u slots, 2 streams, double-buffered) [MEASURED]\n\n",
              sustained_slots);
  std::printf("| Profile | Ports | Dir | Wall ms/slot | Event p50 | Event p99 | Event max |\n");
  std::printf("|---|---:|---|---:|---:|---:|---:|\n");
  for (const case_result& r : results) {
    std::printf("| %s | %u | DL | %.4f | %.4f | %.4f | %.4f |\n",
                r.profile_name.c_str(),
                r.ports,
                r.gpu_dl_sustained_ms_per_slot,
                r.gpu_dl_sustained.p50_ms,
                r.gpu_dl_sustained.p99_ms,
                r.gpu_dl_sustained.max_ms);
    std::printf("| %s | %u | UL | %.4f | %.4f | %.4f | %.4f |\n",
                r.profile_name.c_str(),
                r.ports,
                r.gpu_ul_sustained_ms_per_slot,
                r.gpu_ul_sustained.p50_ms,
                r.gpu_ul_sustained.p99_ms,
                r.gpu_ul_sustained.max_ms);
  }

  std::printf("\nOverall: %s\n", all_pass ? "PASS" : "FAIL");
  return all_pass ? 0 : 1;
}
