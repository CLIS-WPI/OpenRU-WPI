// SPDX-FileCopyrightText: Copyright (C) 2026 Software Radio Systems Limited
// SPDX-License-Identifier: BSD-3-Clause-Open-MPI

#include "lowphy_cuda.h"
#include "ofdm_radix2_reference.h"

#include "iq_compression_bfp_avx2.h"
#include "iq_compression_bfp_impl.h"
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
#include <cmath>
#include <complex>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <random>
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

struct timing {
  double h2d_ms;
  double kernel_ms;
  double d2h_ms;
};

template <typename Launch>
timing measure(Launch       launch,
               void*        device_input,
               const void*  host_input,
               size_t       input_bytes,
               void*        device_output,
               void*        host_output,
               size_t       output_bytes,
               unsigned     iterations,
               cudaStream_t stream)
{
  constexpr unsigned WARMUP = 3;

  for (unsigned i = 0; i != WARMUP; ++i) {
    CUDA_CHECK(cudaMemcpyAsync(device_input, host_input, input_bytes, cudaMemcpyHostToDevice, stream));
    launch();
    CUDA_CHECK(cudaMemcpyAsync(host_output, device_output, output_bytes, cudaMemcpyDeviceToHost, stream));
  }
  CUDA_CHECK(cudaStreamSynchronize(stream));

  cudaEvent_t event_start;
  cudaEvent_t event_input;
  cudaEvent_t event_kernel;
  cudaEvent_t event_output;
  CUDA_CHECK(cudaEventCreate(&event_start));
  CUDA_CHECK(cudaEventCreate(&event_input));
  CUDA_CHECK(cudaEventCreate(&event_kernel));
  CUDA_CHECK(cudaEventCreate(&event_output));

  double h2d    = 0.0;
  double kernel = 0.0;
  double d2h    = 0.0;

  for (unsigned i = 0; i != iterations; ++i) {
    CUDA_CHECK(cudaEventRecord(event_start, stream));
    CUDA_CHECK(cudaMemcpyAsync(device_input, host_input, input_bytes, cudaMemcpyHostToDevice, stream));
    CUDA_CHECK(cudaEventRecord(event_input, stream));

    launch();
    CUDA_CHECK(cudaEventRecord(event_kernel, stream));

    CUDA_CHECK(cudaMemcpyAsync(host_output, device_output, output_bytes, cudaMemcpyDeviceToHost, stream));
    CUDA_CHECK(cudaEventRecord(event_output, stream));
    CUDA_CHECK(cudaEventSynchronize(event_output));

    float elapsed = 0.0f;
    CUDA_CHECK(cudaEventElapsedTime(&elapsed, event_start, event_input));
    h2d += elapsed;
    CUDA_CHECK(cudaEventElapsedTime(&elapsed, event_input, event_kernel));
    kernel += elapsed;
    CUDA_CHECK(cudaEventElapsedTime(&elapsed, event_kernel, event_output));
    d2h += elapsed;
  }

  CUDA_CHECK(cudaEventDestroy(event_start));
  CUDA_CHECK(cudaEventDestroy(event_input));
  CUDA_CHECK(cudaEventDestroy(event_kernel));
  CUDA_CHECK(cudaEventDestroy(event_output));

  CUDA_CHECK(cudaGetLastError());

  return {h2d / iterations, kernel / iterations, d2h / iterations};
}

struct ofdm_timing {
  double h2d_ms;
  double pre_ms;
  double fft_ms;
  double post_ms;
  double d2h_ms;
};

template <typename Pre, typename Fft, typename Post>
ofdm_timing measure_ofdm(Pre          pre,
                         Fft          fft,
                         Post         post,
                         void*        device_input,
                         const void*  host_input,
                         size_t       input_bytes,
                         void*        device_output,
                         void*        host_output,
                         size_t       output_bytes,
                         unsigned     iterations,
                         cudaStream_t stream)
{
  constexpr unsigned WARMUP = 3;

  for (unsigned i = 0; i != WARMUP; ++i) {
    CUDA_CHECK(cudaMemcpyAsync(device_input, host_input, input_bytes, cudaMemcpyHostToDevice, stream));
    pre();
    fft();
    post();
    CUDA_CHECK(cudaMemcpyAsync(host_output, device_output, output_bytes, cudaMemcpyDeviceToHost, stream));
  }
  CUDA_CHECK(cudaStreamSynchronize(stream));

  cudaEvent_t events[6];
  for (cudaEvent_t& event : events) {
    CUDA_CHECK(cudaEventCreate(&event));
  }

  double h2d  = 0.0;
  double pre_ms  = 0.0;
  double fft_ms  = 0.0;
  double post_ms = 0.0;
  double d2h  = 0.0;

  for (unsigned i = 0; i != iterations; ++i) {
    CUDA_CHECK(cudaEventRecord(events[0], stream));
    CUDA_CHECK(cudaMemcpyAsync(device_input, host_input, input_bytes, cudaMemcpyHostToDevice, stream));
    CUDA_CHECK(cudaEventRecord(events[1], stream));

    pre();
    CUDA_CHECK(cudaEventRecord(events[2], stream));

    fft();
    CUDA_CHECK(cudaEventRecord(events[3], stream));

    post();
    CUDA_CHECK(cudaEventRecord(events[4], stream));

    CUDA_CHECK(cudaMemcpyAsync(host_output, device_output, output_bytes, cudaMemcpyDeviceToHost, stream));
    CUDA_CHECK(cudaEventRecord(events[5], stream));
    CUDA_CHECK(cudaEventSynchronize(events[5]));

    float elapsed = 0.0f;
    CUDA_CHECK(cudaEventElapsedTime(&elapsed, events[0], events[1]));
    h2d += elapsed;
    CUDA_CHECK(cudaEventElapsedTime(&elapsed, events[1], events[2]));
    pre_ms += elapsed;
    CUDA_CHECK(cudaEventElapsedTime(&elapsed, events[2], events[3]));
    fft_ms += elapsed;
    CUDA_CHECK(cudaEventElapsedTime(&elapsed, events[3], events[4]));
    post_ms += elapsed;
    CUDA_CHECK(cudaEventElapsedTime(&elapsed, events[4], events[5]));
    d2h += elapsed;
  }

  for (cudaEvent_t event : events) {
    CUDA_CHECK(cudaEventDestroy(event));
  }

  CUDA_CHECK(cudaGetLastError());

  return {h2d / iterations, pre_ms / iterations, fft_ms / iterations, post_ms / iterations, d2h / iterations};
}

struct bfp_result {
  size_t compress_mismatches;
  int    compress_max_diff;
  size_t decompress_mismatches;
  size_t avx2_compress_mismatches;
  size_t avx2_decompress_mismatches;
};

struct ofdm_result {
  size_t mod_mismatches;
  int    mod_max_lsb;
  double mod_error_db;
  double demod_max_lsb;
  size_t demod_mismatches;
  double demod_error_db;
  bool   pass;
};

struct radix2_result {
  std::string profile_name;
  unsigned    dft_size;
  unsigned    ports;
  int         max_lsb;
};

struct timing_case {
  std::string profile_name;
  unsigned    dft_size;
  unsigned    ports;
  timing      bfp9_compress;
  timing      bfp9_decompress;
  timing      bfp16_compress;
  timing      bfp16_decompress;
  ofdm_timing mod;
  ofdm_timing demod;
};

void fill_random_grid(std::vector<ocudu::cbf16_t>& grid, float scale, uint32_t seed)
{
  std::mt19937                          generator(seed);
  std::uniform_real_distribution<float> distribution(-scale, scale);

  for (ocudu::cbf16_t& value : grid) {
    value = ocudu::cbf16_t(distribution(generator), distribution(generator));
  }
}

std::vector<ocudu::cf_t> convert_ci16_to_cf(const std::vector<ocudu::ci16_t>& input)
{
  std::vector<ocudu::cf_t> output(input.size());
  ocudu::ocuduvec::convert(ocudu::span<ocudu::cf_t>(output), ocudu::span<const ocudu::ci16_t>(input), 32767.0f);
  return output;
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

} // namespace

int main(int argc, char** argv)
{
  unsigned iterations = 20;
  for (int i = 1; i < argc; ++i) {
    if ((std::strcmp(argv[i], "--iters") == 0) && (i + 1 < argc)) {
      iterations = static_cast<unsigned>(std::strtoul(argv[++i], nullptr, 10));
    }
  }

  static_assert(sizeof(ocudu::cbf16_t) == 4, "Unexpected cbf16_t layout");

  ocudulog::init();

  CUDA_CHECK(cudaSetDevice(0));

  cudaDeviceProp device_prop;
  CUDA_CHECK(cudaGetDeviceProperties(&device_prop, 0));
  std::printf("# Low PHY CUDA standalone validation\n\n");
  std::printf("Device: %s (compute capability %d.%d)\n\n", device_prop.name, device_prop.major, device_prop.minor);

  const std::vector<profile> profiles = {
      {"20 MHz", 51, 23040000u},
      {"40 MHz", 106, 46080000u},
      {"100 MHz", 273, 122880000u},
  };

  const std::vector<unsigned> port_counts = {2, 4};
  const std::vector<unsigned> data_widths = {8, 9, 10, 12, 16};

  auto& logger = ocudulog::fetch_basic_logger("lowphy_test");
  logger.set_level(ocudulog::basic_levels::warning);

  std::vector<bfp_result> bfp_results(data_widths.size());
  for (bfp_result& result : bfp_results) {
    result = {};
  }

  std::vector<ofdm_result> ofdm_results;
  std::vector<std::string>  ofdm_profile_names;
  std::vector<unsigned>     ofdm_dft_sizes;
  std::vector<unsigned>     ofdm_port_counts;
  std::vector<radix2_result> radix2_results;
  std::vector<timing_case>  timing_results;
  bool                      all_pass = true;

  for (const profile& profile : profiles) {
    const ocudu::subcarrier_spacing scs        = ocudu::subcarrier_spacing::kHz30;
    const ocudu::cyclic_prefix      cp         = ocudu::cyclic_prefix::NORMAL;
    const unsigned                  numerology = ocudu::to_numerology_value(scs);
    const unsigned                  nof_slots_sf   = ocudu::get_nof_slots_per_subframe(scs);
    const unsigned                  nof_symbols_sf = nof_slots_sf * NOF_SYMBOLS_PER_SLOT;
    const ocudu::sampling_rate      srate         = ocudu::sampling_rate::from_Hz(profile.srate_Hz);

    if (!srate.is_valid(scs)) {
      std::fprintf(stderr,
                   "Unsupported sampling rate %u Hz for SCS %u kHz in profile %s.\n",
                   profile.srate_Hz,
                   ocudu::scs_to_khz(scs),
                   profile.name);
      return 1;
    }

    const unsigned dft_size         = srate.get_dft_size(scs);
    const double   sampling_rate_Hz = static_cast<double>(srate.to_Hz());
    const unsigned rg_size          = profile.bw_rb * ocudu::NOF_SUBCARRIERS_PER_RB;
    const unsigned nof_prbs         = profile.bw_rb;
    const bool     power_of_two     = (dft_size & (dft_size - 1)) == 0;

    std::printf("Profile %s: srate %.2f MHz, SCS %u kHz, DFT %u, BW %u PRB\n",
                profile.name,
                srate.to_MHz(),
                ocudu::scs_to_khz(scs),
                dft_size,
                profile.bw_rb);

    if (dft_size <= rg_size) {
      std::fprintf(stderr, "Invalid DFT size %u for resource grid size %u.\n", dft_size, rg_size);
      return 1;
    }

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

    std::vector<lowphy_cf32> phase_mod(nof_symbols_sf);
    std::vector<lowphy_cf32> phase_demod(nof_symbols_sf);
    for (unsigned symbol = 0; symbol != nof_symbols_sf; ++symbol) {
      ocudu::cf_t coefficient = mod_phase.get_coefficient(symbol);
      phase_mod[symbol]       = {coefficient.real(), coefficient.imag()};
      coefficient             = demod_phase.get_coefficient(symbol);
      phase_demod[symbol]     = {coefficient.real(), coefficient.imag()};
    }

    std::vector<lowphy_cf32> twiddles_mod;
    lowphy_cf32*             device_twiddles_mod = nullptr;
    if (power_of_two) {
      twiddles_mod.resize(dft_size / 2);
      const float two_pi = 2.0F * static_cast<float>(M_PI);
      for (unsigned k = 0; k != dft_size / 2; ++k) {
        ocudu::cf_t coefficient =
            std::polar(1.0F, two_pi * static_cast<float>(k) / static_cast<float>(dft_size));
        twiddles_mod[k] = {coefficient.real(), coefficient.imag()};
      }
      CUDA_CHECK(cudaMalloc(&device_twiddles_mod, twiddles_mod.size() * sizeof(lowphy_cf32)));
      CUDA_CHECK(cudaMemcpy(device_twiddles_mod,
                            twiddles_mod.data(),
                            twiddles_mod.size() * sizeof(lowphy_cf32),
                            cudaMemcpyHostToDevice));
    }

    const float mod_scale = 1.0F;
    const float demod_scale =
        1.0F / static_cast<float>(std::sqrt(static_cast<double>(profile.bw_rb * ocudu::NOF_SUBCARRIERS_PER_RB)));

    const size_t grid_elements = static_cast<size_t>(4) * NOF_SYMBOLS_PER_SLOT * rg_size;
    std::vector<ocudu::cbf16_t> grid_bfp(grid_elements);
    std::vector<ocudu::cbf16_t> grid_ofdm(grid_elements);
    fill_random_grid(grid_bfp, 1.0f, 0x1234u + dft_size);
    fill_random_grid(grid_ofdm, GRID_SCALE, 0x5678u + dft_size);

    const size_t grid_bytes = grid_elements * sizeof(ocudu::cbf16_t);

    uint16_t* device_grid = nullptr;
    CUDA_CHECK(cudaMalloc(&device_grid, grid_bytes));

    const unsigned max_nof_ports = port_counts.back();
    uint8_t*       device_port_empty = nullptr;
    CUDA_CHECK(cudaMalloc(&device_port_empty, max_nof_ports));
    std::vector<uint8_t> host_port_empty(max_nof_ports, 0);
    CUDA_CHECK(cudaMemcpy(device_port_empty, host_port_empty.data(), max_nof_ports, cudaMemcpyHostToDevice));

    unsigned* device_cp_len       = nullptr;
    unsigned* device_symbol_start = nullptr;
    CUDA_CHECK(cudaMalloc(&device_cp_len, nof_symbols_sf * sizeof(unsigned)));
    CUDA_CHECK(cudaMalloc(&device_symbol_start, nof_symbols_sf * sizeof(unsigned)));
    CUDA_CHECK(cudaMemcpy(device_cp_len, cp_len.data(), nof_symbols_sf * sizeof(unsigned), cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpy(
        device_symbol_start, symbol_start.data(), nof_symbols_sf * sizeof(unsigned), cudaMemcpyHostToDevice));

    lowphy_cf32* device_phase_mod   = nullptr;
    lowphy_cf32* device_phase_demod = nullptr;
    CUDA_CHECK(cudaMalloc(&device_phase_mod, nof_symbols_sf * sizeof(lowphy_cf32)));
    CUDA_CHECK(cudaMalloc(&device_phase_demod, nof_symbols_sf * sizeof(lowphy_cf32)));
    CUDA_CHECK(cudaMemcpy(
        device_phase_mod, phase_mod.data(), nof_symbols_sf * sizeof(lowphy_cf32), cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpy(
        device_phase_demod, phase_demod.data(), nof_symbols_sf * sizeof(lowphy_cf32), cudaMemcpyHostToDevice));

    cudaStream_t stream;
    CUDA_CHECK(cudaStreamCreate(&stream));

    for (unsigned ports : port_counts) {
      ofdm_result current_ofdm = {};
      timing_case current_timing;
      current_timing.profile_name = profile.name;
      current_timing.dft_size     = dft_size;
      current_timing.ports        = ports;

      const size_t current_grid_bytes = static_cast<size_t>(ports) * NOF_SYMBOLS_PER_SLOT * rg_size * sizeof(ocudu::cbf16_t);

      for (unsigned width : data_widths) {
        const unsigned       prb_size  = 1 + ((24 * width + 7) / 8);
        const size_t         comp_size = static_cast<size_t>(ports) * NOF_SYMBOLS_PER_SLOT * nof_prbs * prb_size;
        std::vector<uint8_t> cpu_comp_generic(comp_size);
        std::vector<uint8_t> cpu_comp_avx2(comp_size);
        std::vector<uint8_t> gpu_comp(comp_size);

        ocudu::ofh::ru_compression_params    params{ocudu::ofh::compression_type::BFP, width};
        ocudu::ofh::iq_compression_bfp_impl  bfp_generic(logger, 1.0f);
        ocudu::ofh::iq_compression_bfp_avx2  bfp_avx2(logger, 1.0f);

        for (unsigned port = 0; port != ports; ++port) {
          for (unsigned symbol = 0; symbol != NOF_SYMBOLS_PER_SLOT; ++symbol) {
            size_t grid_offset = (static_cast<size_t>(port) * NOF_SYMBOLS_PER_SLOT + symbol) * rg_size;
            size_t comp_offset = (static_cast<size_t>(port) * NOF_SYMBOLS_PER_SLOT + symbol) * nof_prbs * prb_size;

            ocudu::span<const ocudu::cbf16_t> input(grid_bfp.data() + grid_offset, rg_size);
            ocudu::span<uint8_t>              output(cpu_comp_generic.data() + comp_offset, nof_prbs * prb_size);
            bfp_generic.compress(output, input, params);

            output = ocudu::span<uint8_t>(cpu_comp_avx2.data() + comp_offset, nof_prbs * prb_size);
            bfp_avx2.compress(output, input, params);
          }
        }

        uint8_t* device_compressed = nullptr;
        CUDA_CHECK(cudaMalloc(&device_compressed, comp_size));
        CUDA_CHECK(cudaMemcpy(device_grid, grid_bfp.data(), current_grid_bytes, cudaMemcpyHostToDevice));
        lowphy_bfp_compress(
            device_grid, device_compressed, ports, NOF_SYMBOLS_PER_SLOT, nof_prbs, width, stream);
        CUDA_CHECK(cudaMemcpy(gpu_comp.data(), device_compressed, comp_size, cudaMemcpyDeviceToHost));
        CUDA_CHECK(cudaStreamSynchronize(stream));

        size_t compress_mismatches      = 0;
        int    compress_max_diff        = 0;
        size_t avx2_compress_mismatches = 0;
        for (size_t i = 0; i != comp_size; ++i) {
          int diff = std::abs(static_cast<int>(gpu_comp[i]) - static_cast<int>(cpu_comp_generic[i]));
          if (diff != 0) {
            ++compress_mismatches;
            compress_max_diff = std::max(compress_max_diff, diff);
          }
          if (cpu_comp_avx2[i] != cpu_comp_generic[i]) {
            ++avx2_compress_mismatches;
          }
        }

        std::vector<ocudu::cbf16_t> cpu_dec_generic(static_cast<size_t>(ports) * NOF_SYMBOLS_PER_SLOT * rg_size);
        std::vector<ocudu::cbf16_t> cpu_dec_avx2(cpu_dec_generic.size());
        std::vector<uint16_t>       gpu_dec(cpu_dec_generic.size() * 2);

        for (unsigned port = 0; port != ports; ++port) {
          for (unsigned symbol = 0; symbol != NOF_SYMBOLS_PER_SLOT; ++symbol) {
            size_t grid_offset = (static_cast<size_t>(port) * NOF_SYMBOLS_PER_SLOT + symbol) * rg_size;
            size_t comp_offset = (static_cast<size_t>(port) * NOF_SYMBOLS_PER_SLOT + symbol) * nof_prbs * prb_size;

            ocudu::span<const uint8_t>  input(cpu_comp_generic.data() + comp_offset, nof_prbs * prb_size);
            ocudu::span<ocudu::cbf16_t> output(cpu_dec_generic.data() + grid_offset, rg_size);
            bfp_generic.decompress(output, input, params);

            output = ocudu::span<ocudu::cbf16_t>(cpu_dec_avx2.data() + grid_offset, rg_size);
            bfp_avx2.decompress(output, input, params);
          }
        }

        uint8_t* device_compressed_padded = nullptr;
        CUDA_CHECK(cudaMalloc(&device_compressed_padded, comp_size + 2));
        CUDA_CHECK(cudaMemset(device_compressed_padded, 0, comp_size + 2));
        CUDA_CHECK(cudaMemcpy(device_compressed_padded, cpu_comp_generic.data(), comp_size, cudaMemcpyHostToDevice));
        lowphy_bfp_decompress(
            device_compressed_padded, device_grid, ports, NOF_SYMBOLS_PER_SLOT, nof_prbs, width, stream);
        CUDA_CHECK(cudaMemcpy(gpu_dec.data(), device_grid, gpu_dec.size() * sizeof(uint16_t), cudaMemcpyDeviceToHost));
        CUDA_CHECK(cudaStreamSynchronize(stream));

        const uint16_t* cpu_dec_bits          = reinterpret_cast<const uint16_t*>(cpu_dec_generic.data());
        size_t          decompress_mismatches = 0;
        for (size_t i = 0; i != gpu_dec.size(); ++i) {
          if (gpu_dec[i] != cpu_dec_bits[i]) {
            ++decompress_mismatches;
          }
        }

        size_t          avx2_decompress_mismatches = 0;
        const uint16_t* avx2_dec_bits              = reinterpret_cast<const uint16_t*>(cpu_dec_avx2.data());
        for (size_t i = 0; i != gpu_dec.size(); ++i) {
          if (avx2_dec_bits[i] != cpu_dec_bits[i]) {
            ++avx2_decompress_mismatches;
          }
        }

        size_t width_index = static_cast<size_t>(std::find(data_widths.begin(), data_widths.end(), width) -
                                                 data_widths.begin());
        bfp_result& result = bfp_results[width_index];
        result.compress_mismatches        = std::max(result.compress_mismatches, compress_mismatches);
        result.compress_max_diff          = std::max(result.compress_max_diff, compress_max_diff);
        result.decompress_mismatches      = std::max(result.decompress_mismatches, decompress_mismatches);
        result.avx2_compress_mismatches   = std::max(result.avx2_compress_mismatches, avx2_compress_mismatches);
        result.avx2_decompress_mismatches = std::max(result.avx2_decompress_mismatches, avx2_decompress_mismatches);

        if ((width == 9) || (width == 16)) {
          void* host_input  = nullptr;
          void* host_output = nullptr;
          CUDA_CHECK(cudaHostAlloc(&host_input, current_grid_bytes, cudaHostAllocDefault));
          CUDA_CHECK(cudaHostAlloc(&host_output, comp_size, cudaHostAllocDefault));
          std::memcpy(host_input, grid_bfp.data(), current_grid_bytes);

          timing compress_timing = measure(
              [&]() {
                lowphy_bfp_compress(
                    device_grid, device_compressed, ports, NOF_SYMBOLS_PER_SLOT, nof_prbs, width, stream);
              },
              device_grid,
              host_input,
              current_grid_bytes,
              device_compressed,
              host_output,
              comp_size,
              iterations,
              stream);

          void* host_compressed = nullptr;
          void* host_decoded    = nullptr;
          CUDA_CHECK(cudaHostAlloc(&host_compressed, comp_size + 2, cudaHostAllocDefault));
          CUDA_CHECK(cudaHostAlloc(&host_decoded, current_grid_bytes, cudaHostAllocDefault));
          std::memcpy(host_compressed, cpu_comp_generic.data(), comp_size);
          std::memset(static_cast<uint8_t*>(host_compressed) + comp_size, 0, 2);

          timing decompress_timing = measure(
              [&]() {
                lowphy_bfp_decompress(
                    device_compressed_padded, device_grid, ports, NOF_SYMBOLS_PER_SLOT, nof_prbs, width, stream);
              },
              device_compressed_padded,
              host_compressed,
              comp_size + 2,
              device_grid,
              host_decoded,
              current_grid_bytes,
              iterations,
              stream);

          if (width == 9) {
            current_timing.bfp9_compress   = compress_timing;
            current_timing.bfp9_decompress = decompress_timing;
          } else {
            current_timing.bfp16_compress   = compress_timing;
            current_timing.bfp16_decompress = decompress_timing;
          }

          CUDA_CHECK(cudaFreeHost(host_input));
          CUDA_CHECK(cudaFreeHost(host_output));
          CUDA_CHECK(cudaFreeHost(host_compressed));
          CUDA_CHECK(cudaFreeHost(host_decoded));
        }

        CUDA_CHECK(cudaFree(device_compressed));
        CUDA_CHECK(cudaFree(device_compressed_padded));
      }

      auto grid_factory = ocudu::create_resource_grid_factory();
      auto grid         = grid_factory->create(ports, NOF_SYMBOLS_PER_SLOT, rg_size);
      for (unsigned port = 0; port != ports; ++port) {
        for (unsigned symbol = 0; symbol != NOF_SYMBOLS_PER_SLOT; ++symbol) {
          auto view = grid->get_writer().get_view(port, symbol);
          std::copy_n(grid_ofdm.data() + (static_cast<size_t>(port) * NOF_SYMBOLS_PER_SLOT + symbol) * rg_size,
                      rg_size,
                      view.begin());
        }
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

      unsigned max_slot_samples = slot_modulator->get_slot_size(0);
      for (unsigned slot = 1; slot != nof_slots_sf; ++slot) {
        max_slot_samples = std::max(max_slot_samples, slot_modulator->get_slot_size(slot));
      }

      lowphy_ofdm_plan* mod_plan = lowphy_ofdm_plan_create(dft_size, ports, NOF_SYMBOLS_PER_SLOT, true);
      lowphy_ofdm_plan* demod_plan = lowphy_ofdm_plan_create(dft_size, ports, NOF_SYMBOLS_PER_SLOT, false);
      if ((mod_plan == nullptr) || (demod_plan == nullptr)) {
        std::fprintf(stderr,
                     "cuFFT plan creation failed for %s (%u ports, DFT %u).\n",
                     profile.name,
                     ports,
                     dft_size);
        return 1;
      }

      int16_t*     device_mod_output   = nullptr;
      int16_t*     device_demod_input  = nullptr;
      lowphy_cf32* device_demod_output = nullptr;
      CUDA_CHECK(cudaMalloc(&device_mod_output,
                            static_cast<size_t>(ports) * max_slot_samples * 2 * sizeof(int16_t)));
      CUDA_CHECK(cudaMalloc(&device_demod_input,
                            static_cast<size_t>(ports) * max_slot_samples * 2 * sizeof(int16_t)));
      CUDA_CHECK(cudaMalloc(&device_demod_output,
                            static_cast<size_t>(ports) * NOF_SYMBOLS_PER_SLOT * rg_size *
                                sizeof(lowphy_cf32)));

      std::vector<ocudu::ci16_t> timing_ci16(static_cast<size_t>(ports) * slot_modulator->get_slot_size(0));

      size_t mod_mismatches       = 0;
      int    mod_max_lsb          = 0;
      double mod_signal_energy    = 0.0;
      double mod_error_energy     = 0.0;
      double demod_max_lsb        = 0.0;
      size_t demod_mismatches     = 0;
      double demod_signal_energy  = 0.0;
      double demod_error_energy   = 0.0;

      for (unsigned slot_index = 0; slot_index != nof_slots_sf; ++slot_index) {
        const unsigned slot_start   = symbol_start[slot_index * NOF_SYMBOLS_PER_SLOT];
        const unsigned slot_samples = slot_modulator->get_slot_size(slot_index);

        std::vector<ocudu::cf_t>   cpu_slot_cf(slot_samples);
        std::vector<ocudu::ci16_t> cpu_ci16(static_cast<size_t>(ports) * slot_samples);
        std::vector<int16_t>       gpu_mod_output(static_cast<size_t>(ports) * slot_samples * 2);

        for (unsigned port = 0; port != ports; ++port) {
          slot_modulator->modulate(ocudu::span<ocudu::cf_t>(cpu_slot_cf), grid->get_reader(), port, slot_index);
          ocudu::ocuduvec::convert(ocudu::span<ocudu::ci16_t>(cpu_ci16.data() + port * slot_samples, slot_samples),
                                   ocudu::span<const ocudu::cf_t>(cpu_slot_cf),
                                   32767.0f);
        }

        if (slot_index == 0) {
          timing_ci16 = cpu_ci16;
        }

        CUDA_CHECK(cudaMemcpy(device_grid, grid_ofdm.data(), current_grid_bytes, cudaMemcpyHostToDevice));

        lowphy_ofdm_mod_params mod_params = {};
        mod_params.plan                   = mod_plan;
        mod_params.grid                   = device_grid;
        mod_params.out                    = device_mod_output;
        mod_params.port_empty             = device_port_empty;
        mod_params.phase                  = device_phase_mod;
        mod_params.cp_len                 = device_cp_len;
        mod_params.symbol_start           = device_symbol_start;
        mod_params.nof_ports              = ports;
        mod_params.nof_symbols_per_slot   = NOF_SYMBOLS_PER_SLOT;
        mod_params.dft_size               = dft_size;
        mod_params.bw_rb                  = profile.bw_rb;
        mod_params.slot_index             = slot_index;
        mod_params.slot_start             = slot_start;
        mod_params.slot_samples           = slot_samples;
        mod_params.scale                  = mod_scale;

        lowphy_ofdm_mod_pre(mod_params, stream);
        lowphy_ofdm_mod_fft(mod_params, stream);
        lowphy_ofdm_mod_post(mod_params, stream);

        CUDA_CHECK(cudaMemcpy(gpu_mod_output.data(),
                              device_mod_output,
                              gpu_mod_output.size() * sizeof(int16_t),
                              cudaMemcpyDeviceToHost));
        CUDA_CHECK(cudaStreamSynchronize(stream));

        const int16_t* cpu_ci16_bits = reinterpret_cast<const int16_t*>(cpu_ci16.data());
        for (size_t i = 0; i != gpu_mod_output.size(); ++i) {
          int diff = std::abs(static_cast<int>(gpu_mod_output[i]) - static_cast<int>(cpu_ci16_bits[i]));
          if (diff != 0) {
            ++mod_mismatches;
            mod_max_lsb = std::max(mod_max_lsb, diff);
          }
          mod_signal_energy += static_cast<double>(cpu_ci16_bits[i]) * static_cast<double>(cpu_ci16_bits[i]);
          mod_error_energy += static_cast<double>(diff) * static_cast<double>(diff);
        }

        std::vector<ocudu::cf_t> cpu_demod_input = convert_ci16_to_cf(cpu_ci16);
        std::vector<ocudu::cf_t> cpu_demod_grid(static_cast<size_t>(ports) * NOF_SYMBOLS_PER_SLOT * rg_size);
        capture_writer           writer(ports, NOF_SYMBOLS_PER_SLOT, rg_size, cpu_demod_grid);

        for (unsigned port = 0; port != ports; ++port) {
          slot_demodulator->demodulate(
              writer,
              ocudu::span<const ocudu::cf_t>(cpu_demod_input.data() + port * slot_samples, slot_samples),
              port,
              slot_index);
        }

        CUDA_CHECK(cudaMemcpy(device_demod_input,
                              cpu_ci16_bits,
                              static_cast<size_t>(ports) * slot_samples * 2 * sizeof(int16_t),
                              cudaMemcpyHostToDevice));

        lowphy_ofdm_demod_params demod_params = {};
        demod_params.plan                     = demod_plan;
        demod_params.in                       = device_demod_input;
        demod_params.grid                     = device_demod_output;
        demod_params.phase                    = device_phase_demod;
        demod_params.window_phase             = nullptr;
        demod_params.cp_len                   = device_cp_len;
        demod_params.symbol_start             = device_symbol_start;
        demod_params.nof_ports                = ports;
        demod_params.nof_symbols_per_slot     = NOF_SYMBOLS_PER_SLOT;
        demod_params.dft_size                 = dft_size;
        demod_params.bw_rb                    = profile.bw_rb;
        demod_params.slot_index               = slot_index;
        demod_params.slot_start               = slot_start;
        demod_params.slot_samples             = slot_samples;
        demod_params.window_offset            = 0;
        demod_params.scale                    = demod_scale;

        lowphy_ofdm_demod_pre(demod_params, stream);
        lowphy_ofdm_demod_fft(demod_params, stream);
        lowphy_ofdm_demod_post(demod_params, stream);

        std::vector<lowphy_cf32> gpu_demod_grid(static_cast<size_t>(ports) * NOF_SYMBOLS_PER_SLOT * rg_size);
        CUDA_CHECK(cudaMemcpy(gpu_demod_grid.data(),
                              device_demod_output,
                              gpu_demod_grid.size() * sizeof(lowphy_cf32),
                              cudaMemcpyDeviceToHost));
        CUDA_CHECK(cudaStreamSynchronize(stream));

        for (size_t i = 0; i != gpu_demod_grid.size(); ++i) {
          double diff_re = static_cast<double>(cpu_demod_grid[i].real()) - gpu_demod_grid[i].re;
          double diff_im = static_cast<double>(cpu_demod_grid[i].imag()) - gpu_demod_grid[i].im;
          double diff    = std::sqrt(diff_re * diff_re + diff_im * diff_im);
          double sig     = static_cast<double>(cpu_demod_grid[i].real()) * static_cast<double>(cpu_demod_grid[i].real()) +
                       static_cast<double>(cpu_demod_grid[i].imag()) * static_cast<double>(cpu_demod_grid[i].imag());

          double diff_lsb = diff * 32767.0;
          demod_max_lsb   = std::max(demod_max_lsb, diff_lsb);
          if (diff_lsb >= 0.5) {
            ++demod_mismatches;
          }
          demod_signal_energy += sig;
          demod_error_energy += diff * diff;
        }
      }

      if (power_of_two) {
        const unsigned ref_samples = slot_modulator->get_slot_size(0);
        int16_t*       device_ref_output = nullptr;
        CUDA_CHECK(cudaMalloc(&device_ref_output, static_cast<size_t>(ports) * ref_samples * 2 * sizeof(int16_t)));

        lowphy_radix2_mod_params ref_params = {};
        ref_params.grid                   = device_grid;
        ref_params.out                    = device_ref_output;
        ref_params.nof_ports              = ports;
        ref_params.nof_symbols_per_slot   = NOF_SYMBOLS_PER_SLOT;
        ref_params.dft_size               = dft_size;
        ref_params.bw_rb                  = profile.bw_rb;
        ref_params.slot_index             = 0;
        ref_params.nof_symbols_per_sf     = nof_symbols_sf;
        ref_params.cp_len                 = device_cp_len;
        ref_params.symbol_start           = device_symbol_start;
        ref_params.slot_start             = symbol_start[0];
        ref_params.slot_samples           = ref_samples;
        ref_params.phase                  = device_phase_mod;
        ref_params.scale                  = mod_scale;
        ref_params.port_empty             = device_port_empty;
        ref_params.twiddles               = device_twiddles_mod;
        ref_params.logn                   = static_cast<unsigned>(std::log2(dft_size));

        lowphy_radix2_modulate(ref_params, stream);

        std::vector<int16_t> ref_out(static_cast<size_t>(ports) * ref_samples * 2);
        CUDA_CHECK(cudaMemcpy(ref_out.data(),
                              device_ref_output,
                              ref_out.size() * sizeof(int16_t),
                              cudaMemcpyDeviceToHost));
        CUDA_CHECK(cudaStreamSynchronize(stream));

        const int16_t* cpu_bits = reinterpret_cast<const int16_t*>(timing_ci16.data());
        int            max_lsb  = 0;
        for (size_t i = 0; i != ref_out.size(); ++i) {
          max_lsb = std::max(max_lsb, std::abs(static_cast<int>(ref_out[i]) - static_cast<int>(cpu_bits[i])));
        }
        radix2_results.push_back({profile.name, dft_size, ports, max_lsb});
        CUDA_CHECK(cudaFree(device_ref_output));
      }

      const unsigned timing_slot_samples = slot_modulator->get_slot_size(0);

      void* host_grid         = nullptr;
      void* host_mod_output   = nullptr;
      void* host_demod_input  = nullptr;
      void* host_demod_output = nullptr;
      CUDA_CHECK(cudaHostAlloc(&host_grid, current_grid_bytes, cudaHostAllocDefault));
      CUDA_CHECK(cudaHostAlloc(&host_mod_output,
                               static_cast<size_t>(ports) * timing_slot_samples * 2 * sizeof(int16_t),
                               cudaHostAllocDefault));
      CUDA_CHECK(cudaHostAlloc(&host_demod_input,
                               static_cast<size_t>(ports) * timing_slot_samples * 2 * sizeof(int16_t),
                               cudaHostAllocDefault));
      CUDA_CHECK(cudaHostAlloc(&host_demod_output,
                               static_cast<size_t>(ports) * NOF_SYMBOLS_PER_SLOT * rg_size *
                                   sizeof(lowphy_cf32),
                               cudaHostAllocDefault));
      std::memcpy(host_grid, grid_ofdm.data(), current_grid_bytes);
      std::memcpy(host_demod_input,
                  timing_ci16.data(),
                  static_cast<size_t>(ports) * timing_slot_samples * 2 * sizeof(int16_t));

      lowphy_ofdm_mod_params mod_params = {};
      mod_params.plan                   = mod_plan;
      mod_params.grid                   = device_grid;
      mod_params.out                    = device_mod_output;
      mod_params.port_empty             = device_port_empty;
      mod_params.phase                  = device_phase_mod;
      mod_params.cp_len                 = device_cp_len;
      mod_params.symbol_start           = device_symbol_start;
      mod_params.nof_ports              = ports;
      mod_params.nof_symbols_per_slot   = NOF_SYMBOLS_PER_SLOT;
      mod_params.dft_size               = dft_size;
      mod_params.bw_rb                  = profile.bw_rb;
      mod_params.slot_index             = 0;
      mod_params.slot_start             = symbol_start[0];
      mod_params.slot_samples           = timing_slot_samples;
      mod_params.scale                  = mod_scale;

      current_timing.mod = measure_ofdm(
          [&]() { lowphy_ofdm_mod_pre(mod_params, stream); },
          [&]() { lowphy_ofdm_mod_fft(mod_params, stream); },
          [&]() { lowphy_ofdm_mod_post(mod_params, stream); },
          device_grid,
          host_grid,
          current_grid_bytes,
          device_mod_output,
          host_mod_output,
          static_cast<size_t>(ports) * timing_slot_samples * 2 * sizeof(int16_t),
          iterations,
          stream);

      lowphy_ofdm_demod_params demod_params = {};
      demod_params.plan                     = demod_plan;
      demod_params.in                       = device_demod_input;
      demod_params.grid                     = device_demod_output;
      demod_params.phase                    = device_phase_demod;
      demod_params.window_phase             = nullptr;
      demod_params.cp_len                   = device_cp_len;
      demod_params.symbol_start             = device_symbol_start;
      demod_params.nof_ports                = ports;
      demod_params.nof_symbols_per_slot     = NOF_SYMBOLS_PER_SLOT;
      demod_params.dft_size                 = dft_size;
      demod_params.bw_rb                    = profile.bw_rb;
      demod_params.slot_index               = 0;
      demod_params.slot_start               = symbol_start[0];
      demod_params.slot_samples             = timing_slot_samples;
      demod_params.window_offset            = 0;
      demod_params.scale                    = demod_scale;

      current_timing.demod = measure_ofdm(
          [&]() { lowphy_ofdm_demod_pre(demod_params, stream); },
          [&]() { lowphy_ofdm_demod_fft(demod_params, stream); },
          [&]() { lowphy_ofdm_demod_post(demod_params, stream); },
          device_demod_input,
          host_demod_input,
          static_cast<size_t>(ports) * timing_slot_samples * 2 * sizeof(int16_t),
          device_demod_output,
          host_demod_output,
          static_cast<size_t>(ports) * NOF_SYMBOLS_PER_SLOT * rg_size * sizeof(lowphy_cf32),
          iterations,
          stream);

      CUDA_CHECK(cudaFreeHost(host_grid));
      CUDA_CHECK(cudaFreeHost(host_mod_output));
      CUDA_CHECK(cudaFreeHost(host_demod_input));
      CUDA_CHECK(cudaFreeHost(host_demod_output));

      current_ofdm.mod_mismatches  = mod_mismatches;
      current_ofdm.mod_max_lsb     = mod_max_lsb;
      current_ofdm.mod_error_db    = power_ratio_db(mod_error_energy, mod_signal_energy);
      current_ofdm.demod_max_lsb   = demod_max_lsb;
      current_ofdm.demod_mismatches = demod_mismatches;
      current_ofdm.demod_error_db  = power_ratio_db(demod_error_energy, demod_signal_energy);
      current_ofdm.pass            = (mod_max_lsb <= 1) && (current_ofdm.mod_error_db <= -60.0) &&
                          (demod_max_lsb <= 1.0) && (current_ofdm.demod_error_db <= -60.0);
      all_pass = all_pass && current_ofdm.pass;

      ofdm_profile_names.push_back(profile.name);
      ofdm_dft_sizes.push_back(dft_size);
      ofdm_port_counts.push_back(ports);
      ofdm_results.push_back(current_ofdm);
      timing_results.push_back(current_timing);

      lowphy_ofdm_plan_destroy(mod_plan);
      lowphy_ofdm_plan_destroy(demod_plan);

      CUDA_CHECK(cudaFree(device_mod_output));
      CUDA_CHECK(cudaFree(device_demod_input));
      CUDA_CHECK(cudaFree(device_demod_output));
    }

    CUDA_CHECK(cudaStreamDestroy(stream));
    CUDA_CHECK(cudaFree(device_grid));
    CUDA_CHECK(cudaFree(device_port_empty));
    CUDA_CHECK(cudaFree(device_cp_len));
    CUDA_CHECK(cudaFree(device_symbol_start));
    CUDA_CHECK(cudaFree(device_phase_mod));
    CUDA_CHECK(cudaFree(device_phase_demod));
    if (device_twiddles_mod != nullptr) {
      CUDA_CHECK(cudaFree(device_twiddles_mod));
    }
  }

  std::printf("\n## BFP correctness\n\n");
  std::printf("| Width | Max compress byte mismatch | Max decompress bf16 mismatch | Max AVX2 compress mismatch | Max AVX2 decompress mismatch |\n");
  std::printf("|---:|---:|---:|---:|---:|\n");
  for (size_t i = 0; i != data_widths.size(); ++i) {
    const bfp_result& result = bfp_results[i];
    std::printf("| %u | %zu | %zu | %zu | %zu |\n",
                data_widths[i],
                result.compress_mismatches,
                result.decompress_mismatches,
                result.avx2_compress_mismatches,
                result.avx2_decompress_mismatches);
  }

  std::printf("\n## OFDM correctness (cuFFT, one launch per stage per slot)\n\n");
  std::printf("| Profile | DFT | Ports | Mod diff | Mod max LSB | Mod error | Demod max LSB | Demod diff | Demod error | Pass |\n");
  std::printf("|---|---:|---:|---:|---:|---:|---:|---:|---:|:---:|\n");
  for (size_t i = 0; i != ofdm_results.size(); ++i) {
    const ofdm_result& result = ofdm_results[i];
    std::printf("| %s | %u | %u | %zu | %d | %.2f dB | %.4f | %zu | %.2f dB | %s |\n",
                ofdm_profile_names[i].c_str(),
                ofdm_dft_sizes[i],
                ofdm_port_counts[i],
                result.mod_mismatches,
                result.mod_max_lsb,
                result.mod_error_db,
                result.demod_max_lsb,
                result.demod_mismatches,
                result.demod_error_db,
                result.pass ? "PASS" : "FAIL");
  }

  std::printf("\n## Radix-2 test-only reference (power-of-two DFT sizes)\n\n");
  if (radix2_results.empty()) {
    std::printf("_No power-of-two DFT size in this run._\n");
  } else {
    std::printf("| Profile | DFT | Ports | Mod max LSB |\n");
    std::printf("|---|---:|---:|---:|\n");
    for (const radix2_result& result : radix2_results) {
      std::printf("| %s | %u | %u | %d |\n", result.profile_name.c_str(), result.dft_size, result.ports, result.max_lsb);
    }
  }

  std::printf("\n## Timing (ms per slot, all ports; kernel is compute-only)\n\n");
  std::printf("| Profile | Ports | BFP9 comp H2D | BFP9 comp kernel | BFP9 comp D2H | BFP9 dec H2D | BFP9 dec kernel | BFP9 dec D2H |\n");
  std::printf("|---|---:|---:|---:|---:|---:|---:|---:|\n");
  for (const timing_case& result : timing_results) {
    std::printf("| %s | %u | %.4f | %.4f | %.4f | %.4f | %.4f | %.4f |\n",
                result.profile_name.c_str(),
                result.ports,
                result.bfp9_compress.h2d_ms,
                result.bfp9_compress.kernel_ms,
                result.bfp9_compress.d2h_ms,
                result.bfp9_decompress.h2d_ms,
                result.bfp9_decompress.kernel_ms,
                result.bfp9_decompress.d2h_ms);
  }

  std::printf("\n| Profile | Ports | BFP16 comp H2D | BFP16 comp kernel | BFP16 comp D2H | BFP16 dec H2D | BFP16 dec kernel | BFP16 dec D2H |\n");
  std::printf("|---|---:|---:|---:|---:|---:|---:|---:|\n");
  for (const timing_case& result : timing_results) {
    std::printf("| %s | %u | %.4f | %.4f | %.4f | %.4f | %.4f | %.4f |\n",
                result.profile_name.c_str(),
                result.ports,
                result.bfp16_compress.h2d_ms,
                result.bfp16_compress.kernel_ms,
                result.bfp16_compress.d2h_ms,
                result.bfp16_decompress.h2d_ms,
                result.bfp16_decompress.kernel_ms,
                result.bfp16_decompress.d2h_ms);
  }

  std::printf("\n| Profile | DFT | Ports | Mod H2D | Mod pre | Mod cuFFT | Mod post | Mod D2H | Mod compute | Demod H2D | Demod pre | Demod cuFFT | Demod post | Demod D2H | Demod compute |\n");
  std::printf("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|\n");
  for (const timing_case& result : timing_results) {
    std::printf("| %s | %u | %u | %.4f | %.4f | %.4f | %.4f | %.4f | %.4f | %.4f | %.4f | %.4f | %.4f | %.4f | %.4f |\n",
                result.profile_name.c_str(),
                result.dft_size,
                result.ports,
                result.mod.h2d_ms,
                result.mod.pre_ms,
                result.mod.fft_ms,
                result.mod.post_ms,
                result.mod.d2h_ms,
                result.mod.pre_ms + result.mod.fft_ms + result.mod.post_ms,
                result.demod.h2d_ms,
                result.demod.pre_ms,
                result.demod.fft_ms,
                result.demod.post_ms,
                result.demod.d2h_ms,
                result.demod.pre_ms + result.demod.fft_ms + result.demod.post_ms);
  }

  std::printf("\nOverall: %s\n", all_pass ? "PASS" : "FAIL");
  return all_pass ? 0 : 1;
}
