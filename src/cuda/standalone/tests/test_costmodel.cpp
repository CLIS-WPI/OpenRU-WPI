// SPDX-FileCopyrightText: Copyright (C) 2026 Software Radio Systems Limited
// SPDX-License-Identifier: BSD-3-Clause-Open-MPI
//
// Cost-model microbenchmarks for the NeoRU RFC.
//
// Measures the existing OpenRU / OCUDU low-PHY kernels separately, per slot:
//   - OFDM modulation (IFFT + CP)
//   - BFP compression (9-bit)
//   - Category-B DL precoding (layers -> ports)
// for 20/40/100 MHz and 1/2/4/8 ports, on CPU (AVX2 or AVX-512 build) and
// GPU (CUDA, H100).
//
// Every backend is checked against a golden/reference before it is timed:
//   - BFP: byte-identical to the generic OCUDU compressor.
//   - OFDM: <= 1 ci16 LSB and <= -60 dB error power vs the generic DFT.
//   - Precoding: max |backend - scalar reference| <= 1e-3 after bf16 -> float.
//
// The GPU path also reports host<->device transfer time per slot.

#include "lowphy_cuda.h"
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
#include "ocudu/phy/lower/modulation/ofdm_modulator.h"
#include "ocudu/phy/lower/sampling_rate.h"
#include "ocudu/phy/support/resource_grid.h"
#include "ocudu/phy/support/resource_grid_reader.h"
#include "ocudu/phy/support/resource_grid_writer.h"
#include "ocudu/phy/support/support_factories.h"
#include "ocudu/ran/cyclic_prefix.h"
#include "ocudu/ran/resource_block.h"
#include "ocudu/ran/subcarrier_spacing.h"

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
constexpr unsigned WARMUP               = 5;
constexpr double   PASS_MAX_ABS_ERR     = 1e-3;

struct profile {
  const char* name;
  unsigned    bw_rb;
  unsigned    srate_Hz;
};

struct latency_stats {
  double p50  = 0.0;
  double p99  = 0.0;
  double maxv = 0.0;
  double mean = 0.0;
};

latency_stats compute_stats(std::vector<double> samples)
{
  latency_stats stats;
  if (samples.empty()) {
    return stats;
  }
  std::sort(samples.begin(), samples.end());
  const size_t n = samples.size();
  stats.p50      = samples[(n * 50) / 100];
  stats.p99      = samples[std::min(n - 1, (n * 99) / 100)];
  stats.maxv     = samples.back();
  double sum     = 0.0;
  for (double v : samples) {
    sum += v;
  }
  stats.mean = sum / static_cast<double>(n);
  return stats;
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
  std::mt19937                          generator(seed);
  std::uniform_real_distribution<float> distribution(-scale, scale);
  for (ocudu::cbf16_t& value : grid) {
    value = ocudu::cbf16_t(distribution(generator), distribution(generator));
  }
}

void fill_weights(std::vector<ocudu::cf_t>& w, unsigned nof_prbs, unsigned nof_ports, unsigned nof_layers, uint32_t seed)
{
  std::mt19937                          generator(seed);
  std::uniform_real_distribution<float> distribution(-1.0f, 1.0f);
  w.resize(static_cast<size_t>(nof_prbs) * nof_ports * nof_layers);
  const float scale = 1.0f / std::sqrt(static_cast<float>(nof_ports));
  for (ocudu::cf_t& c : w) {
    c = ocudu::cf_t(distribution(generator) * scale, distribution(generator) * scale);
  }
}

template <typename Func>
std::vector<double> time_cpu(Func func, unsigned iterations)
{
  for (unsigned i = 0; i != WARMUP; ++i) {
    func();
  }
  std::vector<double> samples;
  samples.reserve(iterations);
  for (unsigned i = 0; i != iterations; ++i) {
    const auto t0 = std::chrono::steady_clock::now();
    func();
    const auto t1 = std::chrono::steady_clock::now();
    samples.push_back(std::chrono::duration<double, std::milli>(t1 - t0).count());
  }
  return samples;
}

struct gpu_timing {
  latency_stats h2d;
  latency_stats compute;
  latency_stats d2h;
};

template <typename Launch>
gpu_timing time_gpu(Launch       launch,
                    void*        device_input,
                    const void*  host_input,
                    size_t       input_bytes,
                    void*        device_output,
                    void*        host_output,
                    size_t       output_bytes,
                    unsigned     iterations,
                    cudaStream_t stream)
{
  for (unsigned i = 0; i != 3; ++i) {
    CUDA_CHECK(cudaMemcpyAsync(device_input, host_input, input_bytes, cudaMemcpyHostToDevice, stream));
    launch();
    CUDA_CHECK(cudaMemcpyAsync(host_output, device_output, output_bytes, cudaMemcpyDeviceToHost, stream));
  }
  CUDA_CHECK(cudaStreamSynchronize(stream));

  cudaEvent_t ev_start;
  cudaEvent_t ev_input;
  cudaEvent_t ev_kernel;
  cudaEvent_t ev_output;
  CUDA_CHECK(cudaEventCreate(&ev_start));
  CUDA_CHECK(cudaEventCreate(&ev_input));
  CUDA_CHECK(cudaEventCreate(&ev_kernel));
  CUDA_CHECK(cudaEventCreate(&ev_output));

  std::vector<double> h2d;
  std::vector<double> kernel;
  std::vector<double> d2h;
  h2d.reserve(iterations);
  kernel.reserve(iterations);
  d2h.reserve(iterations);

  for (unsigned i = 0; i != iterations; ++i) {
    CUDA_CHECK(cudaEventRecord(ev_start, stream));
    CUDA_CHECK(cudaMemcpyAsync(device_input, host_input, input_bytes, cudaMemcpyHostToDevice, stream));
    CUDA_CHECK(cudaEventRecord(ev_input, stream));
    launch();
    CUDA_CHECK(cudaEventRecord(ev_kernel, stream));
    CUDA_CHECK(cudaMemcpyAsync(host_output, device_output, output_bytes, cudaMemcpyDeviceToHost, stream));
    CUDA_CHECK(cudaEventRecord(ev_output, stream));
    CUDA_CHECK(cudaEventSynchronize(ev_output));

    float elapsed = 0.0f;
    CUDA_CHECK(cudaEventElapsedTime(&elapsed, ev_start, ev_input));
    h2d.push_back(elapsed);
    CUDA_CHECK(cudaEventElapsedTime(&elapsed, ev_input, ev_kernel));
    kernel.push_back(elapsed);
    CUDA_CHECK(cudaEventElapsedTime(&elapsed, ev_kernel, ev_output));
    d2h.push_back(elapsed);
  }

  CUDA_CHECK(cudaEventDestroy(ev_start));
  CUDA_CHECK(cudaEventDestroy(ev_input));
  CUDA_CHECK(cudaEventDestroy(ev_kernel));
  CUDA_CHECK(cudaEventDestroy(ev_output));
  CUDA_CHECK(cudaGetLastError());

  return {compute_stats(h2d), compute_stats(kernel), compute_stats(d2h)};
}

double power_ratio_db(double error_energy, double signal_energy)
{
  if (error_energy == 0.0) {
    return -INFINITY;
  }
  if (signal_energy == 0.0) {
    return 0.0;
  }
  return 10.0 * std::log10(error_energy / signal_energy);
}

struct ofdm_check {
  int    max_lsb  = 0;
  double error_db = 0.0;
  bool   pass     = false;
};

ofdm_check check_ofdm_ci16(const std::vector<ocudu::ci16_t>& got, const std::vector<ocudu::ci16_t>& golden)
{
  ofdm_check result;
  double     error_energy  = 0.0;
  double     signal_energy = 0.0;
  for (size_t i = 0; i != got.size(); ++i) {
    const int dr = static_cast<int>(got[i].real()) - static_cast<int>(golden[i].real());
    const int di = static_cast<int>(got[i].imag()) - static_cast<int>(golden[i].imag());
    result.max_lsb = std::max(result.max_lsb, std::max(std::abs(dr), std::abs(di)));
    error_energy += static_cast<double>(dr) * dr + static_cast<double>(di) * di;
    signal_energy += static_cast<double>(golden[i].real()) * golden[i].real() +
                     static_cast<double>(golden[i].imag()) * golden[i].imag();
  }
  result.error_db = power_ratio_db(error_energy, signal_energy);
  result.pass     = (result.max_lsb <= 1) && (result.error_db <= -60.0);
  return result;
}

struct precode_check {
  double max_err = 0.0;
  size_t mismatches = 0;
  bool   pass    = false;
};

precode_check check_precode(const std::vector<ocudu::cbf16_t>& got, const std::vector<ocudu::cbf16_t>& golden)
{
  precode_check result;
  for (size_t i = 0; i != got.size(); ++i) {
    const ocudu::cf_t g = ocudu::to_cf(got[i]);
    const ocudu::cf_t r = ocudu::to_cf(golden[i]);
    const double      e = std::hypot(static_cast<double>(g.real() - r.real()),
                                     static_cast<double>(g.imag() - r.imag()));
    if (e > 1e-5) {
      ++result.mismatches;
    }
    result.max_err = std::max(result.max_err, e);
  }
  result.pass = (result.max_err <= PASS_MAX_ABS_ERR);
  return result;
}

void write_row(std::ofstream& csv,
               const std::string& isa,
               const std::string& backend,
               const std::string& profile_name,
               unsigned           bw_mhz,
               unsigned           dft_size,
               unsigned           ports,
               unsigned           layers,
               const std::string& kernel,
               const latency_stats& h2d,
               const latency_stats& compute,
               const latency_stats& d2h,
               bool               pass,
               const std::string& note)
{
  const double transfer_p50 = h2d.p50 + d2h.p50;
  csv << isa << ',' << backend << ',' << profile_name << ',' << bw_mhz << ',' << dft_size << ',' << ports << ','
      << layers << ',' << kernel << ',' << h2d.p50 << ',' << h2d.p99 << ',' << compute.p50 << ',' << compute.p99
      << ',' << compute.maxv << ',' << d2h.p50 << ',' << d2h.p99 << ',' << transfer_p50 << ','
      << (pass ? "PASS" : "FAIL") << ",\"" << note << "\"\n";
}

} // namespace

int main(int argc, char** argv)
{
  unsigned    iterations = 200;
  unsigned    cpu_core   = 8;
  std::string bfp_impl   = "avx512";
  std::string prec_impl  = "avx512";
  std::string ofdm_impl  = "fftw";
  std::string csv_path   = "costmodel.csv";
  std::string isa        = "unknown";
  bool        skip_gpu   = false;
  bool        skip_cpu   = false;

  for (int i = 1; i < argc; ++i) {
    auto next = [&](const char* name) -> const char* {
      if (i + 1 >= argc) {
        std::fprintf(stderr, "Missing value for %s\n", name);
        std::exit(1);
      }
      return argv[++i];
    };
    if (std::strcmp(argv[i], "--iters") == 0) {
      iterations = static_cast<unsigned>(std::strtoul(next("--iters"), nullptr, 10));
    } else if (std::strcmp(argv[i], "--cpu-core") == 0) {
      cpu_core = static_cast<unsigned>(std::strtoul(next("--cpu-core"), nullptr, 10));
    } else if (std::strcmp(argv[i], "--bfp") == 0) {
      bfp_impl = next("--bfp");
    } else if (std::strcmp(argv[i], "--precoder") == 0) {
      prec_impl = next("--precoder");
    } else if (std::strcmp(argv[i], "--ofdm") == 0) {
      ofdm_impl = next("--ofdm");
    } else if (std::strcmp(argv[i], "--csv") == 0) {
      csv_path = next("--csv");
    } else if (std::strcmp(argv[i], "--isa") == 0) {
      isa = next("--isa");
    } else if (std::strcmp(argv[i], "--skip-gpu") == 0) {
      skip_gpu = true;
    } else if (std::strcmp(argv[i], "--skip-cpu") == 0) {
      skip_cpu = true;
    } else {
      std::fprintf(stderr, "Unknown argument %s\n", argv[i]);
      return 1;
    }
  }

  if (cpu_core > 15) {
    std::fprintf(stderr, "CPU core must be in 0-15 (got %u).\n", cpu_core);
    return 1;
  }
  if (!pin_cpu(cpu_core)) {
    std::fprintf(stderr, "Failed to pin to core %u\n", cpu_core);
    return 1;
  }

  ocudulog::init();
  auto& logger = ocudulog::fetch_basic_logger("costmodel");
  logger.set_level(ocudulog::basic_levels::warning);

  std::ofstream csv(csv_path);
  if (!csv) {
    std::fprintf(stderr, "Cannot open %s\n", csv_path.c_str());
    return 1;
  }
  csv << "isa,backend,profile,bw_mhz,dft_size,ports,layers,kernel,h2d_p50_ms,h2d_p99_ms,"
         "compute_p50_ms,compute_p99_ms,compute_max_ms,d2h_p50_ms,d2h_p99_ms,transfer_p50_ms,pass,note\n";

  const std::vector<profile> profiles = {
      {"20 MHz", 51, 23040000u},
      {"40 MHz", 106, 46080000u},
      {"100 MHz", 273, 122880000u},
  };
  const std::vector<unsigned> port_counts = {1, 2, 4, 8};

  const bool use_gpu = !skip_gpu;
  const bool use_cpu = !skip_cpu;

  std::printf("# Low-PHY cost model\n");
  std::printf("ISA build: %s\n", isa.c_str());
  std::printf("CPU core: %u; iterations: %u\n", cpu_core, iterations);
  std::printf("OFDM backend: %s; BFP backend: %s; precoder backend: %s\n",
              ofdm_impl.c_str(),
              bfp_impl.c_str(),
              prec_impl.c_str());
  std::printf("GPU: %s\n\n", use_gpu ? "enabled (CUDA_VISIBLE_DEVICES)" : "disabled");

  cudaStream_t stream = nullptr;
  if (use_gpu) {
    CUDA_CHECK(cudaStreamCreate(&stream));
  }

  bool all_pass = true;

  for (const profile& profile : profiles) {
    const ocudu::subcarrier_spacing scs        = ocudu::subcarrier_spacing::kHz30;
    const ocudu::cyclic_prefix      cp         = ocudu::cyclic_prefix::NORMAL;
    const unsigned                  numerology = ocudu::to_numerology_value(scs);
    const unsigned                  nof_slots_sf   = ocudu::get_nof_slots_per_subframe(scs);
    const unsigned                  nof_symbols_sf = nof_slots_sf * NOF_SYMBOLS_PER_SLOT;
    const ocudu::sampling_rate      srate         = ocudu::sampling_rate::from_Hz(profile.srate_Hz);
    const unsigned                  dft_size      = srate.get_dft_size(scs);
    const double                    sampling_rate_Hz = static_cast<double>(srate.to_Hz());
    const unsigned                  rg_size          = profile.bw_rb * ocudu::NOF_SUBCARRIERS_PER_RB;
    const unsigned                  nof_prbs         = profile.bw_rb;
    const unsigned                  prb_size         = 1 + ((24 * DATA_WIDTH + 7) / 8);
    const float                     mod_scale        = 1.0f;

    std::vector<unsigned> cp_len(nof_symbols_sf);
    std::vector<unsigned> symbol_start(nof_symbols_sf);
    unsigned              sample_offset = 0;
    for (unsigned symbol = 0; symbol != nof_symbols_sf; ++symbol) {
      cp_len[symbol]       = cp.get_length(symbol, scs).to_samples(sampling_rate_Hz);
      symbol_start[symbol] = sample_offset;
      sample_offset += cp_len[symbol] + dft_size;
    }

    ocudu::phase_compensation_lut mod_phase(scs, cp, dft_size, CENTER_FREQ_HZ, true);
    std::vector<lowphy_cf32>      phase_mod(nof_symbols_sf);
    for (unsigned symbol = 0; symbol != nof_symbols_sf; ++symbol) {
      ocudu::cf_t coefficient = mod_phase.get_coefficient(symbol);
      phase_mod[symbol]       = {coefficient.real(), coefficient.imag()};
    }

    // Factories.
    auto dft_generic = ocudu::create_dft_processor_factory_generic();
    std::shared_ptr<ocudu::dft_processor_factory> dft_timed = dft_generic;
    if (ofdm_impl == "fftw") {
      dft_timed = ocudu::create_dft_processor_factory_fftw_fast();
      if (!dft_timed) {
        std::fprintf(stderr, "FFTW DFT factory unavailable in this build.\n");
        return 1;
      }
    } else if (ofdm_impl != "generic") {
      std::fprintf(stderr, "Unknown --ofdm %s (fftw|generic)\n", ofdm_impl.c_str());
      return 1;
    }

    ocudu::ofdm_factory_generic_configuration mod_cfg_generic{dft_generic};
    ocudu::ofdm_factory_generic_configuration mod_cfg_timed{dft_timed};
    auto mod_factory_generic = ocudu::create_ofdm_modulator_factory_generic(mod_cfg_generic);
    auto mod_factory_timed   = ocudu::create_ofdm_modulator_factory_generic(mod_cfg_timed);

    ocudu::ofdm_modulator_configuration mod_config = {
        .numerology     = numerology,
        .bw_rb          = profile.bw_rb,
        .dft_size       = dft_size,
        .cp             = cp,
        .scale          = mod_scale,
        .center_freq_Hz = CENTER_FREQ_HZ,
    };

    auto grid_factory = ocudu::create_resource_grid_factory();

    for (unsigned ports : port_counts) {
      const unsigned layers = std::min(ports, ocudu::precoding_constants::MAX_NOF_LAYERS);

      const size_t grid_elems = static_cast<size_t>(ports) * NOF_SYMBOLS_PER_SLOT * rg_size;
      const size_t comp_bytes = static_cast<size_t>(ports) * NOF_SYMBOLS_PER_SLOT * nof_prbs * prb_size;

      std::vector<ocudu::cbf16_t> grid_src(grid_elems);
      fill_random_grid(grid_src, GRID_SCALE, 0xC0FFEEu + dft_size * 16u + ports);

      auto grid = grid_factory->create(ports, NOF_SYMBOLS_PER_SLOT, rg_size);
      for (unsigned port = 0; port != ports; ++port) {
        for (unsigned symbol = 0; symbol != NOF_SYMBOLS_PER_SLOT; ++symbol) {
          auto view = grid->get_writer().get_view(port, symbol);
          std::copy_n(grid_src.data() + (static_cast<size_t>(port) * NOF_SYMBOLS_PER_SLOT + symbol) * rg_size,
                      rg_size,
                      view.begin());
        }
      }

      auto golden_modulator = mod_factory_generic->create_ofdm_slot_modulator(mod_config);
      auto timed_modulator  = mod_factory_timed->create_ofdm_slot_modulator(mod_config);
      if (!golden_modulator || !timed_modulator) {
        std::fprintf(stderr, "Failed to create OFDM modulator for %s / %u ports\n", profile.name, ports);
        return 1;
      }
      const unsigned slot_samples = golden_modulator->get_slot_size(0);

      // ---- OFDM golden (generic DFT) ----
      std::vector<ocudu::cf_t>    slot_cf(slot_samples);
      std::vector<ocudu::ci16_t>  golden_ci16(static_cast<size_t>(ports) * slot_samples);
      std::vector<ocudu::ci16_t>  timed_ci16(static_cast<size_t>(ports) * slot_samples);
      for (unsigned port = 0; port != ports; ++port) {
        golden_modulator->modulate(ocudu::span<ocudu::cf_t>(slot_cf), grid->get_reader(), port, 0);
        ocudu::ocuduvec::convert(
            ocudu::span<ocudu::ci16_t>(golden_ci16.data() + port * slot_samples, slot_samples),
            ocudu::span<const ocudu::cf_t>(slot_cf),
            32767.0f);
      }

      auto run_ofdm = [&]() {
        for (unsigned port = 0; port != ports; ++port) {
          timed_modulator->modulate(ocudu::span<ocudu::cf_t>(slot_cf), grid->get_reader(), port, 0);
          ocudu::ocuduvec::convert(
              ocudu::span<ocudu::ci16_t>(timed_ci16.data() + port * slot_samples, slot_samples),
              ocudu::span<const ocudu::cf_t>(slot_cf),
              32767.0f);
        }
      };
      run_ofdm();
      ofdm_check ofdm_cpu_check = check_ofdm_ci16(timed_ci16, golden_ci16);
      all_pass                  = all_pass && ofdm_cpu_check.pass;

      // ---- BFP golden (generic) and timed backend ----
      ocudu::ofh::ru_compression_params params{ocudu::ofh::compression_type::BFP, DATA_WIDTH};
      auto golden_compressor = ocudu::ofh::create_iq_compressor(
          ocudu::ofh::compression_type::BFP, logger, 1.0f, "generic");
      auto timed_compressor = ocudu::ofh::create_iq_compressor(
          ocudu::ofh::compression_type::BFP, logger, 1.0f, bfp_impl);
      if (!golden_compressor || !timed_compressor) {
        std::fprintf(stderr, "Failed to create BFP compressor (backend %s)\n", bfp_impl.c_str());
        return 1;
      }

      std::vector<uint8_t> golden_comp(comp_bytes);
      std::vector<uint8_t> timed_comp(comp_bytes);
      auto run_compress = [&](ocudu::ofh::iq_compressor& compressor, std::vector<uint8_t>& out) {
        for (unsigned port = 0; port != ports; ++port) {
          for (unsigned symbol = 0; symbol != NOF_SYMBOLS_PER_SLOT; ++symbol) {
            const size_t grid_offset =
                (static_cast<size_t>(port) * NOF_SYMBOLS_PER_SLOT + symbol) * rg_size;
            const size_t comp_offset =
                (static_cast<size_t>(port) * NOF_SYMBOLS_PER_SLOT + symbol) * nof_prbs * prb_size;
            compressor.compress(ocudu::span<uint8_t>(out.data() + comp_offset, nof_prbs * prb_size),
                                ocudu::span<const ocudu::cbf16_t>(grid_src.data() + grid_offset, rg_size),
                                params);
          }
        }
      };
      run_compress(*golden_compressor, golden_comp);
      run_compress(*timed_compressor, timed_comp);
      const bool bfp_cpu_pass = (timed_comp == golden_comp);
      all_pass                = all_pass && bfp_cpu_pass;

      // ---- Precoding golden (scalar) and timed OCUDU kernel ----
      std::vector<ocudu::cf_t> weights;
      fill_weights(weights, nof_prbs, ports, layers, 0xBEEFu + ports);
      cpu_catb::WeightBank weight_bank;
      weight_bank.build(weights, nof_prbs, ports, layers);

      std::vector<ocudu::cf_t> layer_grid_cf;
      cpu_catb::layers_cbf16_to_cf(layer_grid_cf, grid_src, layers, rg_size);

      auto precoder_factory = ocudu::create_channel_precoder_factory(prec_impl);
      auto precoder         = precoder_factory ? precoder_factory->create() : nullptr;
      if (!precoder) {
        std::fprintf(stderr, "Failed to create channel precoder (backend %s)\n", prec_impl.c_str());
        return 1;
      }

      std::vector<ocudu::cbf16_t> golden_precoded;
      cpu_catb::precode_reference(golden_precoded, layer_grid_cf, weight_bank);
      std::vector<ocudu::cbf16_t> timed_precoded;
      auto run_precode = [&]() {
        cpu_catb::precode_ocudu_prg_views(timed_precoded, layer_grid_cf, weight_bank, precoder.get());
      };
      run_precode();
      precode_check prec_cpu_check = check_precode(timed_precoded, golden_precoded);
      all_pass                     = all_pass && prec_cpu_check.pass;

      // ---- CPU timing ----
      if (use_cpu) {
      {
        auto ofdm_stats = compute_stats(time_cpu(run_ofdm, iterations));
        write_row(csv,
                  isa,
                  "CPU",
                  profile.name,
                  profile.bw_rb == 51 ? 20u : (profile.bw_rb == 106 ? 40u : 100u),
                  dft_size,
                  ports,
                  layers,
                  "ofdm_mod",
                  {},
                  ofdm_stats,
                  {},
                  ofdm_cpu_check.pass,
                  "FFTW=" + ofdm_impl + "; golden=generic DFT; max_lsb=" +
                      std::to_string(ofdm_cpu_check.max_lsb) + "; err_db=" +
                      std::to_string(ofdm_cpu_check.error_db));
        std::printf("%-7s %-4s %-6s p=%u  OFDM  p50=%.4f p99=%.4f ms  %s\n",
                    profile.name,
                    isa.c_str(),
                    "CPU",
                    ports,
                    ofdm_stats.p50,
                    ofdm_stats.p99,
                    ofdm_cpu_check.pass ? "PASS" : "FAIL");
      }
      {
        auto bfp_stats = compute_stats(time_cpu([&]() { run_compress(*timed_compressor, timed_comp); }, iterations));
        write_row(csv,
                  isa,
                  "CPU",
                  profile.name,
                  profile.bw_rb == 51 ? 20u : (profile.bw_rb == 106 ? 40u : 100u),
                  dft_size,
                  ports,
                  layers,
                  "bfp_compress",
                  {},
                  bfp_stats,
                  {},
                  bfp_cpu_pass,
                  "backend=" + bfp_impl + "; byte-identical to generic");
        std::printf("%-7s %-4s %-6s p=%u  BFP   p50=%.4f p99=%.4f ms  %s\n",
                    profile.name,
                    isa.c_str(),
                    "CPU",
                    ports,
                    bfp_stats.p50,
                    bfp_stats.p99,
                    bfp_cpu_pass ? "PASS" : "FAIL");
      }
      {
        auto prec_stats = compute_stats(time_cpu(run_precode, iterations));
        write_row(csv,
                  isa,
                  "CPU",
                  profile.name,
                  profile.bw_rb == 51 ? 20u : (profile.bw_rb == 106 ? 40u : 100u),
                  dft_size,
                  ports,
                  layers,
                  "precoding",
                  {},
                  prec_stats,
                  {},
                  prec_cpu_check.pass,
                  "backend=" + prec_impl + "; layers=" + std::to_string(layers) + "; max_err=" +
                      std::to_string(prec_cpu_check.max_err));
        std::printf("%-7s %-4s %-6s p=%u  PREC  p50=%.4f p99=%.4f ms  %s\n",
                    profile.name,
                    isa.c_str(),
                    "CPU",
                    ports,
                    prec_stats.p50,
                    prec_stats.p99,
                    prec_cpu_check.pass ? "PASS" : "FAIL");
      }
      }

      if (!use_gpu) {
        continue;
      }

      // ---- GPU timing and correctness ----
      const size_t grid_bytes = grid_elems * sizeof(ocudu::cbf16_t);
      const size_t ci16_bytes = static_cast<size_t>(ports) * slot_samples * sizeof(ocudu::ci16_t);
      const size_t layer_grid_elems = static_cast<size_t>(layers) * NOF_SYMBOLS_PER_SLOT * rg_size;
      const size_t layer_grid_bytes = layer_grid_elems * sizeof(ocudu::cbf16_t);
      const size_t weights_elems    = static_cast<size_t>(nof_prbs) * ports * layers;

      // OFDM: device grid -> ci16.
      uint16_t* d_grid = nullptr;
      int16_t*  d_ci16 = nullptr;
      uint8_t*  d_port_empty = nullptr;
      unsigned* d_cp = nullptr;
      unsigned* d_symbol_start = nullptr;
      lowphy_cf32* d_phase = nullptr;
      CUDA_CHECK(cudaMalloc(&d_grid, grid_bytes));
      CUDA_CHECK(cudaMalloc(&d_ci16, ci16_bytes));
      CUDA_CHECK(cudaMalloc(&d_port_empty, ports));
      CUDA_CHECK(cudaMemset(d_port_empty, 0, ports));
      CUDA_CHECK(cudaMalloc(&d_cp, nof_symbols_sf * sizeof(unsigned)));
      CUDA_CHECK(cudaMalloc(&d_symbol_start, nof_symbols_sf * sizeof(unsigned)));
      CUDA_CHECK(cudaMalloc(&d_phase, nof_symbols_sf * sizeof(lowphy_cf32)));
      CUDA_CHECK(cudaMemcpy(d_cp, cp_len.data(), nof_symbols_sf * sizeof(unsigned), cudaMemcpyHostToDevice));
      CUDA_CHECK(cudaMemcpy(
          d_symbol_start, symbol_start.data(), nof_symbols_sf * sizeof(unsigned), cudaMemcpyHostToDevice));
      CUDA_CHECK(cudaMemcpy(d_phase, phase_mod.data(), nof_symbols_sf * sizeof(lowphy_cf32), cudaMemcpyHostToDevice));
      CUDA_CHECK(cudaMemcpy(d_grid, grid_src.data(), grid_bytes, cudaMemcpyHostToDevice));

      lowphy_ofdm_plan* mod_plan = lowphy_ofdm_plan_create(dft_size, ports, NOF_SYMBOLS_PER_SLOT, true);
      if (!mod_plan) {
        std::fprintf(stderr, "cuFFT mod plan failed for %u ports\n", ports);
        return 1;
      }

      lowphy_ofdm_mod_params mod{};
      mod.plan                 = mod_plan;
      mod.grid                 = d_grid;
      mod.out                  = d_ci16;
      mod.port_empty           = d_port_empty;
      mod.phase                = d_phase;
      mod.cp_len               = d_cp;
      mod.symbol_start         = d_symbol_start;
      mod.nof_ports            = ports;
      mod.nof_symbols_per_slot = NOF_SYMBOLS_PER_SLOT;
      mod.dft_size             = dft_size;
      mod.bw_rb                = nof_prbs;
      mod.slot_index           = 0;
      mod.slot_start           = 0;
      mod.slot_samples         = slot_samples;
      mod.scale                = mod_scale;

      auto run_ofdm_gpu = [&]() {
        lowphy_ofdm_mod_pre(mod, stream);
        lowphy_ofdm_mod_fft(mod, stream);
        lowphy_ofdm_mod_post(mod, stream);
      };

      // Correctness run.
      CUDA_CHECK(cudaMemcpy(d_grid, grid_src.data(), grid_bytes, cudaMemcpyHostToDevice));
      run_ofdm_gpu();
      std::vector<ocudu::ci16_t> gpu_ci16(static_cast<size_t>(ports) * slot_samples);
      CUDA_CHECK(cudaMemcpy(gpu_ci16.data(), d_ci16, ci16_bytes, cudaMemcpyDeviceToHost));
      CUDA_CHECK(cudaStreamSynchronize(stream));
      ofdm_check ofdm_gpu_check = check_ofdm_ci16(gpu_ci16, golden_ci16);
      all_pass                  = all_pass && ofdm_gpu_check.pass;

      std::vector<ocudu::ci16_t> host_ci16(static_cast<size_t>(ports) * slot_samples);
      gpu_timing ofdm_timing = time_gpu(run_ofdm_gpu,
                                        d_grid,
                                        grid_src.data(),
                                        grid_bytes,
                                        d_ci16,
                                        host_ci16.data(),
                                        ci16_bytes,
                                        iterations,
                                        stream);
      write_row(csv,
                isa,
                "GPU",
                profile.name,
                profile.bw_rb == 51 ? 20u : (profile.bw_rb == 106 ? 40u : 100u),
                dft_size,
                ports,
                layers,
                "ofdm_mod",
                ofdm_timing.h2d,
                ofdm_timing.compute,
                ofdm_timing.d2h,
                ofdm_gpu_check.pass,
                "cuFFT; golden=generic CPU DFT; max_lsb=" + std::to_string(ofdm_gpu_check.max_lsb) +
                    "; err_db=" + std::to_string(ofdm_gpu_check.error_db));
      std::printf("%-7s %-4s %-6s p=%u  OFDM  p50=%.4f p99=%.4f ms  H2D=%.4f D2H=%.4f  %s\n",
                  profile.name,
                  isa.c_str(),
                  "GPU",
                  ports,
                  ofdm_timing.compute.p50,
                  ofdm_timing.compute.p99,
                  ofdm_timing.h2d.p50,
                  ofdm_timing.d2h.p50,
                  ofdm_gpu_check.pass ? "PASS" : "FAIL");

      lowphy_ofdm_plan_destroy(mod_plan);
      CUDA_CHECK(cudaFree(d_grid));
      CUDA_CHECK(cudaFree(d_ci16));
      CUDA_CHECK(cudaFree(d_port_empty));
      CUDA_CHECK(cudaFree(d_cp));
      CUDA_CHECK(cudaFree(d_symbol_start));
      CUDA_CHECK(cudaFree(d_phase));

      // BFP compress: device grid -> compressed bytes.
      uint8_t* d_comp = nullptr;
      CUDA_CHECK(cudaMalloc(&d_comp, comp_bytes));
      // Correctness.
      uint16_t* d_grid_bfp = nullptr;
      CUDA_CHECK(cudaMalloc(&d_grid_bfp, grid_bytes));
      CUDA_CHECK(cudaMemcpy(d_grid_bfp, grid_src.data(), grid_bytes, cudaMemcpyHostToDevice));
      lowphy_bfp_compress(d_grid_bfp, d_comp, ports, NOF_SYMBOLS_PER_SLOT, nof_prbs, DATA_WIDTH, stream);
      std::vector<uint8_t> gpu_comp(comp_bytes);
      CUDA_CHECK(cudaMemcpy(gpu_comp.data(), d_comp, comp_bytes, cudaMemcpyDeviceToHost));
      CUDA_CHECK(cudaStreamSynchronize(stream));
      const bool bfp_gpu_pass = (gpu_comp == golden_comp);
      all_pass                = all_pass && bfp_gpu_pass;

      std::vector<uint8_t> host_comp(comp_bytes);
      gpu_timing bfp_timing = time_gpu([&]() { lowphy_bfp_compress(d_grid_bfp, d_comp, ports, NOF_SYMBOLS_PER_SLOT, nof_prbs, DATA_WIDTH, stream); },
                                       d_grid_bfp,
                                       grid_src.data(),
                                       grid_bytes,
                                       d_comp,
                                       host_comp.data(),
                                       comp_bytes,
                                       iterations,
                                       stream);
      write_row(csv,
                isa,
                "GPU",
                profile.name,
                profile.bw_rb == 51 ? 20u : (profile.bw_rb == 106 ? 40u : 100u),
                dft_size,
                ports,
                layers,
                "bfp_compress",
                bfp_timing.h2d,
                bfp_timing.compute,
                bfp_timing.d2h,
                bfp_gpu_pass,
                "byte-identical to generic CPU compressor");
      std::printf("%-7s %-4s %-6s p=%u  BFP   p50=%.4f p99=%.4f ms  H2D=%.4f D2H=%.4f  %s\n",
                  profile.name,
                  isa.c_str(),
                  "GPU",
                  ports,
                  bfp_timing.compute.p50,
                  bfp_timing.compute.p99,
                  bfp_timing.h2d.p50,
                  bfp_timing.d2h.p50,
                  bfp_gpu_pass ? "PASS" : "FAIL");

      CUDA_CHECK(cudaFree(d_grid_bfp));
      CUDA_CHECK(cudaFree(d_comp));

      // Precoding: layers cbf16 -> ports cbf16. Weights are pre-stored on device.
      uint16_t*    d_layer_cbf16 = nullptr;
      uint16_t*    d_port_cbf16  = nullptr;
      lowphy_cf32* d_weights     = nullptr;
      CUDA_CHECK(cudaMalloc(&d_layer_cbf16, layer_grid_bytes));
      CUDA_CHECK(cudaMalloc(&d_port_cbf16, grid_bytes));
      CUDA_CHECK(cudaMalloc(&d_weights, weights_elems * sizeof(lowphy_cf32)));
      std::vector<lowphy_cf32> weights_cf(weights_elems);
      for (size_t i = 0; i != weights_elems; ++i) {
        weights_cf[i] = {weights[i].real(), weights[i].imag()};
      }
      CUDA_CHECK(cudaMemcpy(d_layer_cbf16, grid_src.data(), layer_grid_bytes, cudaMemcpyHostToDevice));
      CUDA_CHECK(cudaMemcpy(d_weights, weights_cf.data(), weights_elems * sizeof(lowphy_cf32), cudaMemcpyHostToDevice));
      auto run_precode_gpu = [&]() {
        lowphy_catb_precode(
            d_layer_cbf16, d_weights, d_port_cbf16, layers, ports, NOF_SYMBOLS_PER_SLOT, nof_prbs, stream);
      };
      // Correctness.
      run_precode_gpu();
      std::vector<ocudu::cbf16_t> gpu_precoded(grid_elems);
      CUDA_CHECK(cudaMemcpy(gpu_precoded.data(), d_port_cbf16, grid_bytes, cudaMemcpyDeviceToHost));
      CUDA_CHECK(cudaStreamSynchronize(stream));
      precode_check prec_gpu_check = check_precode(gpu_precoded, golden_precoded);
      all_pass                      = all_pass && prec_gpu_check.pass;

      std::vector<ocudu::cbf16_t> host_precoded(grid_elems);
      gpu_timing prec_timing = time_gpu(run_precode_gpu,
                                        d_layer_cbf16,
                                        grid_src.data(),
                                        layer_grid_bytes,
                                        d_port_cbf16,
                                        host_precoded.data(),
                                        grid_bytes,
                                        iterations,
                                        stream);
      write_row(csv,
                isa,
                "GPU",
                profile.name,
                profile.bw_rb == 51 ? 20u : (profile.bw_rb == 106 ? 40u : 100u),
                dft_size,
                ports,
                layers,
                "precoding",
                prec_timing.h2d,
                prec_timing.compute,
                prec_timing.d2h,
                prec_gpu_check.pass,
                "CUDA Cat-B; layers=" + std::to_string(layers) + "; weights pre-stored on device; max_err=" +
                    std::to_string(prec_gpu_check.max_err));
      std::printf("%-7s %-4s %-6s p=%u  PREC  p50=%.4f p99=%.4f ms  H2D=%.4f D2H=%.4f  %s\n",
                  profile.name,
                  isa.c_str(),
                  "GPU",
                  ports,
                  prec_timing.compute.p50,
                  prec_timing.compute.p99,
                  prec_timing.h2d.p50,
                  prec_timing.d2h.p50,
                  prec_gpu_check.pass ? "PASS" : "FAIL");

      CUDA_CHECK(cudaFree(d_layer_cbf16));
      CUDA_CHECK(cudaFree(d_port_cbf16));
      CUDA_CHECK(cudaFree(d_weights));
    }
  }

  if (use_gpu) {
    CUDA_CHECK(cudaStreamDestroy(stream));
  }
  csv.close();

  std::printf("\nOverall: %s\n", all_pass ? "PASS" : "FAIL");
  std::printf("CSV: %s\n", csv_path.c_str());
  return all_pass ? 0 : 1;
}
