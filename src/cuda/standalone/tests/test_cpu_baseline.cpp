// SPDX-FileCopyrightText: Copyright (C) 2026 Software Radio Systems Limited
// SPDX-License-Identifier: BSD-3-Clause-Open-MPI
//
// Fair CPU baseline for the device-resident pipeline comparison.
// Times OCUDU BFP + OFDM (DL and UL) under selectable DFT / BFP backends.

#include "iq_compression_bfp_avx2.h"
#include "iq_compression_bfp_avx512.h"
#include "phase_compensation_lut.h"

#include "ocudu/adt/bf16.h"
#include "ocudu/adt/complex.h"
#include "ocudu/ocuduvec/conversion.h"
#include "ocudu/ocudulog/ocudulog.h"
#include "ocudu/ofh/compression/compression_factory.h"
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
#include "ocudu/ran/resource_block.h"
#include "ocudu/ran/subcarrier_spacing.h"
#include "ocudu/support/cpu_features.h"

#include <algorithm>
#include <atomic>
#include <cctype>
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
#include <thread>
#include <vector>

namespace {

constexpr unsigned NOF_SYMBOLS_PER_SLOT = 14;
constexpr float    CENTER_FREQ_HZ       = 3.5e9f;
constexpr float    GRID_SCALE           = 1.0f / 128.0f;
constexpr unsigned DATA_WIDTH           = 9;
constexpr unsigned LATENCY_ITERS        = 200;
constexpr unsigned WARMUP               = 10;
constexpr double   SLOT_DURATION_MS     = 0.5; // 30 kHz SCS

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
  put(unsigned port, unsigned l, unsigned k_init, const ocudu::bounded_bitset<ocudu::MAX_NOF_SUBCARRIERS>& mask,
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
  put(unsigned port, unsigned l, unsigned k_init, const ocudu::bounded_bitset<ocudu::MAX_NOF_SUBCARRIERS>& mask,
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

unsigned cores_needed(double p99_ms)
{
  return static_cast<unsigned>(std::ceil(p99_ms / SLOT_DURATION_MS));
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

struct core_idle_sample {
  double min_idle_pct  = 100.0;
  double mean_idle_pct = 100.0;
  unsigned samples     = 0;
};

/// Sample /proc/stat idle percentage for one logical CPU while `running` is true.
void sample_core_idle(unsigned core, std::atomic<bool>& running, core_idle_sample& out)
{
  auto read_idle_total = [core](uint64_t& idle, uint64_t& total) -> bool {
    std::ifstream in("/proc/stat");
    if (!in) {
      return false;
    }
    std::string line;
    const std::string target = "cpu" + std::to_string(core);
    while (std::getline(in, line)) {
      if (line.compare(0, target.size(), target) != 0 || !std::isspace(static_cast<unsigned char>(line[target.size()]))) {
        continue;
      }
      // cpuN user nice system idle iowait irq softirq steal guest guest_nice
      unsigned long long u = 0, n = 0, s = 0, i = 0, io = 0, irq = 0, soft = 0, st = 0;
      if (std::sscanf(line.c_str() + target.size(),
                      " %llu %llu %llu %llu %llu %llu %llu %llu",
                      &u,
                      &n,
                      &s,
                      &i,
                      &io,
                      &irq,
                      &soft,
                      &st) < 4) {
        return false;
      }
      idle  = i + io;
      total = u + n + s + i + io + irq + soft + st;
      return true;
    }
    return false;
  };

  uint64_t prev_idle = 0, prev_total = 0;
  if (!read_idle_total(prev_idle, prev_total)) {
    return;
  }

  double sum_idle = 0.0;
  out.min_idle_pct = 100.0;
  out.samples      = 0;

  while (running.load(std::memory_order_relaxed)) {
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    uint64_t idle = 0, total = 0;
    if (!read_idle_total(idle, total) || total <= prev_total) {
      continue;
    }
    const double didle  = static_cast<double>(idle - prev_idle);
    const double dtotal = static_cast<double>(total - prev_total);
    const double pct    = 100.0 * didle / dtotal;
    out.min_idle_pct = std::min(out.min_idle_pct, pct);
    sum_idle += pct;
    ++out.samples;
    prev_idle  = idle;
    prev_total = total;
  }
  if (out.samples != 0) {
    out.mean_idle_pct = sum_idle / static_cast<double>(out.samples);
  }
}

enum class dft_backend { generic, fftw };
enum class bfp_backend { avx2, avx512 };

const char* dft_name(dft_backend b)
{
  return b == dft_backend::fftw ? "FFTW" : "generic";
}

const char* bfp_name(bfp_backend b)
{
  return b == bfp_backend::avx512 ? "AVX-512" : "AVX2";
}

struct case_result {
  std::string   profile_name;
  unsigned      dft_size = 0;
  unsigned      ports    = 0;
  latency_stats dl;
  latency_stats ul;
  unsigned      cores_dl   = 0;
  unsigned      cores_ul   = 0;
  unsigned      cores_both = 0;
};

} // namespace

int main(int argc, char** argv)
{
  unsigned    latency_iters = LATENCY_ITERS;
  unsigned    cpu_core      = 8;
  dft_backend dft_sel       = dft_backend::fftw;
  bfp_backend bfp_sel       = bfp_backend::avx512;
  bool        only_20_2     = false;

  for (int i = 1; i < argc; ++i) {
    if ((std::strcmp(argv[i], "--latency-iters") == 0) && (i + 1 < argc)) {
      latency_iters = static_cast<unsigned>(std::strtoul(argv[++i], nullptr, 10));
    } else if ((std::strcmp(argv[i], "--cpu-core") == 0) && (i + 1 < argc)) {
      cpu_core = static_cast<unsigned>(std::strtoul(argv[++i], nullptr, 10));
    } else if ((std::strcmp(argv[i], "--dft") == 0) && (i + 1 < argc)) {
      ++i;
      if (std::strcmp(argv[i], "fftw") == 0) {
        dft_sel = dft_backend::fftw;
      } else if (std::strcmp(argv[i], "generic") == 0) {
        dft_sel = dft_backend::generic;
      } else {
        std::fprintf(stderr, "Unknown --dft %s (fftw|generic)\n", argv[i]);
        return 1;
      }
    } else if ((std::strcmp(argv[i], "--bfp") == 0) && (i + 1 < argc)) {
      ++i;
      if (std::strcmp(argv[i], "avx512") == 0) {
        bfp_sel = bfp_backend::avx512;
      } else if (std::strcmp(argv[i], "avx2") == 0) {
        bfp_sel = bfp_backend::avx2;
      } else {
        std::fprintf(stderr, "Unknown --bfp %s (avx512|avx2)\n", argv[i]);
        return 1;
      }
    } else if (std::strcmp(argv[i], "--only-20-2") == 0) {
      only_20_2 = true;
    }
  }

  if (cpu_core > 15) {
    std::fprintf(stderr, "CPU core must be in 0-15 (got %u).\n", cpu_core);
    return 1;
  }

  ocudulog::init();
  auto& logger = ocudulog::fetch_basic_logger("cpu_baseline");
  logger.set_level(ocudulog::basic_levels::warning);

  const bool have_avx512 = ocudu::cpu_supports_feature(ocudu::cpu_feature::avx512f) &&
                           ocudu::cpu_supports_feature(ocudu::cpu_feature::avx512vl) &&
                           ocudu::cpu_supports_feature(ocudu::cpu_feature::avx512bw) &&
                           ocudu::cpu_supports_feature(ocudu::cpu_feature::avx512dq) &&
                           ocudu::cpu_supports_feature(ocudu::cpu_feature::avx512cd) &&
                           ocudu::cpu_supports_feature(ocudu::cpu_feature::avx512vbmi);

  std::shared_ptr<ocudu::dft_processor_factory> dft_factory;
  if (dft_sel == dft_backend::fftw) {
    dft_factory = ocudu::create_dft_processor_factory_fftw_fast();
    if (!dft_factory) {
      std::fprintf(stderr, "FFTW DFT factory unavailable (HAVE_FFTW not compiled in).\n");
      return 1;
    }
  } else {
    dft_factory = ocudu::create_dft_processor_factory_generic();
  }

  // Confirm BFP path selection matches compression_factory.cpp auto/avx512 rules.
  auto probe = ocudu::ofh::create_iq_compressor(
      ocudu::ofh::compression_type::BFP, logger, 1.0f, bfp_sel == bfp_backend::avx512 ? "avx512" : "avx2");
  if (!probe) {
    std::fprintf(stderr, "Failed to create BFP compressor for requested backend.\n");
    return 1;
  }

  std::printf("# Fair CPU baseline (compute-only)\n\n");
  std::printf("Host CPU: AMD EPYC 9354; pinned core %u (0-15)\n", cpu_core);
  std::printf("DFT backend: %s (factory %s)\n",
              dft_name(dft_sel),
              dft_sel == dft_backend::fftw ? "create_dft_processor_factory_fftw_fast" : "create_dft_processor_factory_generic");
  std::printf("BFP backend: %s via create_iq_compressor(..., \"%s\")\n",
              bfp_name(bfp_sel),
              bfp_sel == bfp_backend::avx512 ? "avx512" : "avx2");
  std::printf("CPU feature probe: avx512f/vl/bw/dq/cd/vbmi = %s\n", have_avx512 ? "all present" : "MISSING");
#if defined(__AVX512F__) && defined(__AVX512BW__)
  std::printf("Compile-time: __AVX512F__/__AVX512BW__ defined (ocuduvec AVX-512 paths enabled)\n");
#else
  std::printf("Compile-time: __AVX512F__/__AVX512BW__ NOT defined\n");
#endif
  std::printf("CMake: ENABLE_FFTW (external/proto-ru/CMakeLists.txt:66), "
              "wired in lib/phy/generic_functions/CMakeLists.txt:26-44; "
              "MARCH (CMakeLists.txt:563-571)\n");
  std::printf("BFP AVX-512 class: lib/ofh/compression/iq_compression_bfp_avx512.cpp; "
              "selected in compression_factory.cpp:54-67\n");
  std::printf("Slot duration for cores_needed: %.1f ms (30 kHz SCS)\n\n", SLOT_DURATION_MS);

  if ((bfp_sel == bfp_backend::avx512) && !have_avx512) {
    std::fprintf(stderr, "AVX-512 requested but CPU features incomplete.\n");
    return 1;
  }

  if (!pin_cpu(cpu_core)) {
    std::fprintf(stderr, "Failed to pin to core %u\n", cpu_core);
    return 1;
  }

  // Pre-run idle: core should be mostly idle if no competing load before we start.
  core_idle_sample pre_idle;
  {
    std::atomic<bool> pre_run{true};
    std::thread       pre_thread(sample_core_idle, cpu_core, std::ref(pre_run), std::ref(pre_idle));
    std::this_thread::sleep_for(std::chrono::seconds(2));
    pre_run.store(false);
    pre_thread.join();
    std::printf("Pre-run core %u idle (2 s): mean=%.2f%% min=%.2f%% over %u samples\n",
                cpu_core,
                pre_idle.mean_idle_pct,
                pre_idle.min_idle_pct,
                pre_idle.samples);
    if (pre_idle.mean_idle_pct < 95.0) {
      std::printf("WARNING: core %u was not idle before the run — competing load likely.\n", cpu_core);
    } else {
      std::printf("Core %u was idle before the run (no competing load detected).\n", cpu_core);
    }
  }

  const std::vector<profile> profiles = {
      {"20 MHz", 51, 23040000u},
      {"40 MHz", 106, 46080000u},
      {"100 MHz", 273, 122880000u},
  };
  const std::vector<unsigned> port_counts = {2, 4};

  std::vector<case_result> results;
  core_idle_sample         idle_stats;
  std::atomic<bool>        sampling{true};
  std::thread              idle_thread(sample_core_idle, cpu_core, std::ref(sampling), std::ref(idle_stats));

  for (const profile& profile : profiles) {
    if (only_20_2 && std::strcmp(profile.name, "20 MHz") != 0) {
      continue;
    }

    const ocudu::subcarrier_spacing scs            = ocudu::subcarrier_spacing::kHz30;
    const ocudu::cyclic_prefix      cp             = ocudu::cyclic_prefix::NORMAL;
    const unsigned                  numerology     = ocudu::to_numerology_value(scs);
    const ocudu::sampling_rate      srate          = ocudu::sampling_rate::from_Hz(profile.srate_Hz);
    const unsigned                  dft_size       = srate.get_dft_size(scs);
    const unsigned                  rg_size        = profile.bw_rb * ocudu::NOF_SUBCARRIERS_PER_RB;
    const unsigned                  nof_prbs       = profile.bw_rb;
    const unsigned                  prb_size       = 1 + ((24 * DATA_WIDTH + 7) / 8);
    const float                     mod_scale      = 1.0f;
    const float                     demod_scale =
        1.0f / static_cast<float>(std::sqrt(static_cast<double>(profile.bw_rb * ocudu::NOF_SUBCARRIERS_PER_RB)));

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

    auto           slot_modulator   = mod_factory->create_ofdm_slot_modulator(modulator_config);
    auto           slot_demodulator = demod_factory->create_ofdm_slot_demodulator(demodulator_config);
    const unsigned slot_index       = 0;
    const unsigned slot_samples     = slot_modulator->get_slot_size(slot_index);

    std::printf("Profile %s: DFT %u, BW %u PRB, slot_samples %u\n",
                profile.name,
                dft_size,
                profile.bw_rb,
                slot_samples);

    for (unsigned ports : port_counts) {
      if (only_20_2 && ports != 2) {
        continue;
      }

      const size_t grid_elems = static_cast<size_t>(ports) * NOF_SYMBOLS_PER_SLOT * rg_size;
      const size_t comp_bytes = static_cast<size_t>(ports) * NOF_SYMBOLS_PER_SLOT * nof_prbs * prb_size;

      std::vector<ocudu::cbf16_t> grid_src(grid_elems);
      fill_random_grid(grid_src, GRID_SCALE, 0xA11Cu + dft_size * 16u + ports);

      auto grid_factory = ocudu::create_resource_grid_factory();
      ocudu::ofh::ru_compression_params params{ocudu::ofh::compression_type::BFP, DATA_WIDTH};

      std::unique_ptr<ocudu::ofh::iq_compressor>   compressor;
      std::unique_ptr<ocudu::ofh::iq_decompressor> decompressor;
      if (bfp_sel == bfp_backend::avx512) {
        compressor   = ocudu::ofh::create_iq_compressor(ocudu::ofh::compression_type::BFP, logger, 1.0f, "avx512");
        decompressor = ocudu::ofh::create_iq_decompressor(ocudu::ofh::compression_type::BFP, logger, "avx512");
      } else {
        compressor   = ocudu::ofh::create_iq_compressor(ocudu::ofh::compression_type::BFP, logger, 1.0f, "avx2");
        decompressor = ocudu::ofh::create_iq_decompressor(ocudu::ofh::compression_type::BFP, logger, "avx2");
      }

      std::vector<uint8_t> host_compressed_src(comp_bytes);
      for (unsigned port = 0; port != ports; ++port) {
        for (unsigned symbol = 0; symbol != NOF_SYMBOLS_PER_SLOT; ++symbol) {
          size_t grid_offset = (static_cast<size_t>(port) * NOF_SYMBOLS_PER_SLOT + symbol) * rg_size;
          size_t comp_offset = (static_cast<size_t>(port) * NOF_SYMBOLS_PER_SLOT + symbol) * nof_prbs * prb_size;
          compressor->compress(ocudu::span<uint8_t>(host_compressed_src.data() + comp_offset, nof_prbs * prb_size),
                               ocudu::span<const ocudu::cbf16_t>(grid_src.data() + grid_offset, rg_size),
                               params);
        }
      }

      // Reference ci16 for UL input: decompress + modulate once.
      std::vector<ocudu::cbf16_t> cpu_decompressed(grid_elems);
      for (unsigned port = 0; port != ports; ++port) {
        for (unsigned symbol = 0; symbol != NOF_SYMBOLS_PER_SLOT; ++symbol) {
          size_t grid_offset = (static_cast<size_t>(port) * NOF_SYMBOLS_PER_SLOT + symbol) * rg_size;
          size_t comp_offset = (static_cast<size_t>(port) * NOF_SYMBOLS_PER_SLOT + symbol) * nof_prbs * prb_size;
          decompressor->decompress(ocudu::span<ocudu::cbf16_t>(cpu_decompressed.data() + grid_offset, rg_size),
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

      std::vector<ocudu::cbf16_t> dec_scratch(grid_elems);
      std::vector<ocudu::cf_t>    slot_cf(slot_samples);
      std::vector<ocudu::ci16_t>  out_ci16(static_cast<size_t>(ports) * slot_samples);
      auto                        timed_grid = grid_factory->create(ports, NOF_SYMBOLS_PER_SLOT, rg_size);

      auto cpu_dl_once = [&]() {
        for (unsigned port = 0; port != ports; ++port) {
          for (unsigned symbol = 0; symbol != NOF_SYMBOLS_PER_SLOT; ++symbol) {
            size_t grid_offset = (static_cast<size_t>(port) * NOF_SYMBOLS_PER_SLOT + symbol) * rg_size;
            size_t comp_offset = (static_cast<size_t>(port) * NOF_SYMBOLS_PER_SLOT + symbol) * nof_prbs * prb_size;
            decompressor->decompress(ocudu::span<ocudu::cbf16_t>(dec_scratch.data() + grid_offset, rg_size),
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
            compressor->compress(ocudu::span<uint8_t>(ul_comp.data() + comp_offset, nof_prbs * prb_size),
                                 ocudu::span<const ocudu::cbf16_t>(demod_grid_bf.data() + grid_offset, rg_size),
                                 params);
          }
        }
      };

      for (unsigned i = 0; i != WARMUP; ++i) {
        cpu_dl_once();
        cpu_ul_once();
      }

      std::vector<double> dl_ms;
      std::vector<double> ul_ms;
      dl_ms.reserve(latency_iters);
      ul_ms.reserve(latency_iters);
      for (unsigned i = 0; i != latency_iters; ++i) {
        const auto t0 = std::chrono::steady_clock::now();
        cpu_dl_once();
        const auto t1 = std::chrono::steady_clock::now();
        dl_ms.push_back(std::chrono::duration<double, std::milli>(t1 - t0).count());

        const auto t2 = std::chrono::steady_clock::now();
        cpu_ul_once();
        const auto t3 = std::chrono::steady_clock::now();
        ul_ms.push_back(std::chrono::duration<double, std::milli>(t3 - t2).count());
      }

      case_result current;
      current.profile_name = profile.name;
      current.dft_size     = dft_size;
      current.ports        = ports;
      current.dl           = compute_stats(dl_ms);
      current.ul           = compute_stats(ul_ms);
      current.cores_dl     = cores_needed(current.dl.p99_ms);
      current.cores_ul     = cores_needed(current.ul.p99_ms);
      current.cores_both   = cores_needed(current.dl.p99_ms + current.ul.p99_ms);
      results.push_back(current);

      std::printf("  %u ports DL p50/p99/max=%.4f/%.4f/%.4f ms (cores_needed=%u)\n",
                  ports,
                  current.dl.p50_ms,
                  current.dl.p99_ms,
                  current.dl.max_ms,
                  current.cores_dl);
      std::printf("  %u ports UL p50/p99/max=%.4f/%.4f/%.4f ms (cores_needed=%u); TDD cores=%u; FDD cores=%u\n",
                  current.ports,
                  current.ul.p50_ms,
                  current.ul.p99_ms,
                  current.ul.max_ms,
                  current.cores_ul,
                  std::max(current.cores_dl, current.cores_ul),
                  current.cores_both);
    }
  }

  sampling.store(false, std::memory_order_relaxed);
  idle_thread.join();

  std::printf("\n## CPU isolation (core %u via /proc/stat)\n\n", cpu_core);
  std::printf("Pre-run idle: mean=%.2f%% min=%.2f%% (%u samples)\n",
              pre_idle.mean_idle_pct,
              pre_idle.min_idle_pct,
              pre_idle.samples);
  std::printf("During-run idle: mean=%.2f%% min=%.2f%% (%u samples)\n",
              idle_stats.mean_idle_pct,
              idle_stats.min_idle_pct,
              idle_stats.samples);
  std::printf("During-run idle near 0%% is expected: the pinned benchmark owns the core.\n");
  std::printf("Isolation verdict: %s\n",
              (pre_idle.mean_idle_pct >= 95.0) ? "PASS (core idle before run)"
                                               : "WARN (pre-run idle < 95%)");

  std::printf("\n## CPU latency (ms) — %s DFT + %s BFP, 1 core\n\n", dft_name(dft_sel), bfp_name(bfp_sel));
  std::printf("| Profile | Ports | Dir | p50 | p99 | max | cores_needed |\n");
  std::printf("|---|---:|---|---:|---:|---:|---:|\n");
  for (const case_result& r : results) {
    std::printf("| %s | %u | DL | %.4f | %.4f | %.4f | %u |\n",
                r.profile_name.c_str(),
                r.ports,
                r.dl.p50_ms,
                r.dl.p99_ms,
                r.dl.max_ms,
                r.cores_dl);
    std::printf("| %s | %u | UL | %.4f | %.4f | %.4f | %u |\n",
                r.profile_name.c_str(),
                r.ports,
                r.ul.p50_ms,
                r.ul.p99_ms,
                r.ul.max_ms,
                r.cores_ul);
  }

  std::printf("\n## GPU replaces N CPU cores\n\n");
  std::printf("| Profile | Ports | DL cores | UL cores | TDD cores | FDD cores (DL+UL) |\n");
  std::printf("|---|---:|---:|---:|---:|---:|\n");
  for (const case_result& r : results) {
    std::printf("| %s | %u | %u | %u | %u | %u |\n",
                r.profile_name.c_str(),
                r.ports,
                r.cores_dl,
                r.cores_ul,
                std::max(r.cores_dl, r.cores_ul),
                r.cores_both);
  }

  return 0;
}
