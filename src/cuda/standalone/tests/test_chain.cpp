// SPDX-FileCopyrightText: Copyright (C) 2026 Software Radio Systems Limited
// SPDX-License-Identifier: BSD-3-Clause-Open-MPI

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
#include <unistd.h>
#include <vector>

namespace {

constexpr unsigned NOF_SYMBOLS = 14;
constexpr unsigned DATA_WIDTH  = 9;
constexpr float    CENTER_HZ   = 3.5e9f;
constexpr float    GRID_SCALE  = 1.0f / 128.0f;
constexpr unsigned WARMUP      = 5;

struct profile { const char* name; unsigned bw_rb; unsigned srate_Hz; };
struct stats { double p50 = 0, p99 = 0, max = 0; };

stats compute_stats(std::vector<double> v)
{
  stats s{};
  if (v.empty()) return s;
  std::sort(v.begin(), v.end());
  s.p50 = v[(v.size() * 50) / 100];
  s.p99 = v[std::min(v.size() - 1, (v.size() * 99) / 100)];
  s.max = v.back();
  return s;
}

void check(cudaError_t e, const char* call)
{
  if (e != cudaSuccess) { std::fprintf(stderr, "CUDA %s: %s\n", call, cudaGetErrorString(e)); std::exit(1); }
}
#define CK(x) check((x), #x)

bool pin_cpu(unsigned core)
{
  cpu_set_t set;
  CPU_ZERO(&set);
  CPU_SET(core, &set);
  return sched_setaffinity(0, sizeof(set), &set) == 0;
}

void fill_random(std::vector<ocudu::cbf16_t>& grid, uint32_t seed)
{
  std::mt19937 gen(seed);
  std::uniform_real_distribution<float> dist(-GRID_SCALE, GRID_SCALE);
  for (auto& v : grid) v = ocudu::cbf16_t(dist(gen), dist(gen));
}

void fill_weights(std::vector<ocudu::cf_t>& w, unsigned prbs, unsigned ports, unsigned layers, uint32_t seed)
{
  std::mt19937 gen(seed);
  std::uniform_real_distribution<float> dist(-1.0f, 1.0f);
  const float scale = 1.0f / std::sqrt(static_cast<float>(ports));
  w.resize(static_cast<size_t>(prbs) * ports * layers);
  for (auto& c : w) c = ocudu::cf_t(dist(gen) * scale, dist(gen) * scale);
}

} // namespace

int main(int argc, char** argv)
{
  unsigned iters = 200, cpu_core = 8;
  std::string csv = "gpu_chain.csv";
  for (int i = 1; i < argc; ++i) {
    if (!std::strcmp(argv[i], "--iters") && i + 1 < argc) iters = std::strtoul(argv[++i], nullptr, 10);
    else if (!std::strcmp(argv[i], "--cpu-core") && i + 1 < argc) cpu_core = std::strtoul(argv[++i], nullptr, 10);
    else if (!std::strcmp(argv[i], "--csv") && i + 1 < argc) csv = argv[++i];
  }
  if (cpu_core >= static_cast<unsigned>(sysconf(_SC_NPROCESSORS_ONLN)) || !pin_cpu(cpu_core)) {
    std::fprintf(stderr, "invalid CPU core %u\n", cpu_core);
    return 1;
  }
  ocudulog::init();
  auto& logger = ocudulog::fetch_basic_logger("gpu_chain");
  logger.set_level(ocudulog::basic_levels::warning);

  std::ofstream out(csv);
  out << "profile,bw_mhz,ports,layers,kernel,h2d_p50_ms,h2d_p99_ms,compute_p50_ms,compute_p99_ms,"
         "d2h_p50_ms,d2h_p99_ms,e2e_p50_ms,e2e_p99_ms,pass,note\n";

  const std::vector<profile> profiles = {{"20 MHz", 51, 23040000u}, {"40 MHz", 106, 46080000u},
                                         {"100 MHz", 273, 122880000u}};
  const std::vector<unsigned> port_counts = {2, 4, 8};
  const ocudu::subcarrier_spacing scs = ocudu::subcarrier_spacing::kHz30;
  const ocudu::cyclic_prefix cp = ocudu::cyclic_prefix::NORMAL;
  const unsigned numerology = ocudu::to_numerology_value(scs);
  const unsigned nof_slots_sf = ocudu::get_nof_slots_per_subframe(scs);
  const unsigned nof_symbols_sf = nof_slots_sf * NOF_SYMBOLS;

  cudaEvent_t e_h0, e_h1, e_c1, e_d1;
  cudaStream_t stream;
  CK(cudaStreamCreate(&stream));
  CK(cudaEventCreate(&e_h0)); CK(cudaEventCreate(&e_h1));
  CK(cudaEventCreate(&e_c1)); CK(cudaEventCreate(&e_d1));

  auto dft_generic = ocudu::create_dft_processor_factory_generic();
  ocudu::ofdm_factory_generic_configuration ofdm_cfg{dft_generic};
  auto mod_factory = ocudu::create_ofdm_modulator_factory_generic(ofdm_cfg);
  auto grid_factory = ocudu::create_resource_grid_factory();

  bool all_pass = true;
  for (const auto& p : profiles) {
    const ocudu::sampling_rate srate = ocudu::sampling_rate::from_Hz(p.srate_Hz);
    const unsigned dft = srate.get_dft_size(scs);
    const unsigned rg = p.bw_rb * ocudu::NOF_SUBCARRIERS_PER_RB;
    const unsigned prb_size = 1 + ((24 * DATA_WIDTH + 7) / 8);
    const double srate_hz = static_cast<double>(srate.to_Hz());
    std::vector<unsigned> cp_len(nof_symbols_sf), sym_start(nof_symbols_sf);
    unsigned off = 0;
    for (unsigned s = 0; s != nof_symbols_sf; ++s) {
      cp_len[s] = cp.get_length(s, scs).to_samples(srate_hz);
      sym_start[s] = off;
      off += cp_len[s] + dft;
    }
    ocudu::phase_compensation_lut lut(scs, cp, dft, CENTER_HZ, true);
    std::vector<lowphy_cf32> phase(nof_symbols_sf);
    for (unsigned s = 0; s != nof_symbols_sf; ++s) {
      auto c = lut.get_coefficient(s);
      phase[s] = {c.real(), c.imag()};
    }
    ocudu::ofdm_modulator_configuration mod_cfg = {
        .numerology = numerology, .bw_rb = p.bw_rb, .dft_size = dft, .cp = cp,
        .scale = 1.0f, .center_freq_Hz = CENTER_HZ};
    auto slot_mod = mod_factory->create_ofdm_slot_modulator(mod_cfg);
    const unsigned slot_samples = slot_mod->get_slot_size(0);

    for (unsigned ports : port_counts) {
      const unsigned layers = std::min(ports, ocudu::precoding_constants::MAX_NOF_LAYERS);
      const size_t layer_elems = static_cast<size_t>(layers) * NOF_SYMBOLS * rg;
      const size_t comp_bytes = static_cast<size_t>(layers) * NOF_SYMBOLS * p.bw_rb * prb_size;
      const size_t grid_bytes = static_cast<size_t>(ports) * NOF_SYMBOLS * rg * sizeof(uint16_t);
      const size_t ci16_bytes = static_cast<size_t>(ports) * slot_samples * sizeof(int16_t);

      // Layer grid, compressed input for the single H2D.
      std::vector<ocudu::cbf16_t> layer_grid(layer_elems);
      fill_random(layer_grid, 0x1234u + ports + p.bw_rb);
      ocudu::ofh::ru_compression_params compr{ocudu::ofh::compression_type::BFP, DATA_WIDTH};
      auto compressor = ocudu::ofh::create_iq_compressor(ocudu::ofh::compression_type::BFP, logger, 1.0f, "generic");
      std::vector<uint8_t> h_comp(comp_bytes);
      for (unsigned l = 0; l != layers; ++l)
        for (unsigned s = 0; s != NOF_SYMBOLS; ++s)
          compressor->compress(
              ocudu::span<uint8_t>(h_comp.data() + (static_cast<size_t>(l) * NOF_SYMBOLS + s) * p.bw_rb * prb_size,
                                   p.bw_rb * prb_size),
              ocudu::span<const ocudu::cbf16_t>(layer_grid.data() + (static_cast<size_t>(l) * NOF_SYMBOLS + s) * rg, rg),
              compr);

      // CPU golden chain: decompress -> Cat-B -> generic OFDM.
      auto decompressor = ocudu::ofh::create_iq_decompressor(ocudu::ofh::compression_type::BFP, logger, "generic");
      std::vector<ocudu::cbf16_t> dec(layer_elems);
      for (unsigned l = 0; l != layers; ++l)
        for (unsigned s = 0; s != NOF_SYMBOLS; ++s)
          decompressor->decompress(
              ocudu::span<ocudu::cbf16_t>(dec.data() + (static_cast<size_t>(l) * NOF_SYMBOLS + s) * rg, rg),
              ocudu::span<const uint8_t>(h_comp.data() + (static_cast<size_t>(l) * NOF_SYMBOLS + s) * p.bw_rb * prb_size,
                                         p.bw_rb * prb_size), compr);

      std::vector<ocudu::cf_t> weights;
      fill_weights(weights, p.bw_rb, ports, layers, 0xBEEFu + ports);
      cpu_catb::WeightBank bank;
      bank.build(weights, p.bw_rb, ports, layers);
      std::vector<ocudu::cf_t> layer_cf;
      cpu_catb::layers_cbf16_to_cf(layer_cf, dec, layers, rg);
      std::vector<ocudu::cbf16_t> golden_port;
      cpu_catb::precode_reference(golden_port, layer_cf, bank);

      auto grid = grid_factory->create(ports, NOF_SYMBOLS, rg);
      for (unsigned port = 0; port != ports; ++port)
        for (unsigned s = 0; s != NOF_SYMBOLS; ++s) {
          auto view = grid->get_writer().get_view(port, s);
          std::copy_n(golden_port.data() + (static_cast<size_t>(port) * NOF_SYMBOLS + s) * rg, rg, view.begin());
        }
      std::vector<ocudu::ci16_t> golden(static_cast<size_t>(ports) * slot_samples);
      std::vector<ocudu::cf_t> slot_cf(slot_samples);
      for (unsigned port = 0; port != ports; ++port) {
        slot_mod->modulate(ocudu::span<ocudu::cf_t>(slot_cf), grid->get_reader(), port, 0);
        ocudu::ocuduvec::convert(ocudu::span<ocudu::ci16_t>(golden.data() + port * slot_samples, slot_samples),
                                 ocudu::span<const ocudu::cf_t>(slot_cf), 32767.0f);
      }

      // Device buffers.
      uint8_t* d_comp = nullptr; uint16_t* d_dec = nullptr; uint16_t* d_port = nullptr;
      int16_t* d_ci16 = nullptr; lowphy_cf32* d_w = nullptr; lowphy_cf32* d_phase = nullptr;
      unsigned* d_cp = nullptr; unsigned* d_start = nullptr;
      CK(cudaMalloc(&d_comp, comp_bytes)); CK(cudaMalloc(&d_dec, layer_elems * sizeof(uint16_t)));
      CK(cudaMalloc(&d_port, grid_bytes)); CK(cudaMalloc(&d_ci16, ci16_bytes));
      std::vector<lowphy_cf32> wsim(weights.size());
      for (size_t i = 0; i != weights.size(); ++i) wsim[i] = {weights[i].real(), weights[i].imag()};
      CK(cudaMalloc(&d_w, wsim.size() * sizeof(lowphy_cf32)));
      CK(cudaMemcpy(d_w, wsim.data(), wsim.size() * sizeof(lowphy_cf32), cudaMemcpyHostToDevice));
      CK(cudaMalloc(&d_phase, phase.size() * sizeof(lowphy_cf32)));
      CK(cudaMemcpy(d_phase, phase.data(), phase.size() * sizeof(lowphy_cf32), cudaMemcpyHostToDevice));
      CK(cudaMalloc(&d_cp, cp_len.size() * sizeof(unsigned)));
      CK(cudaMemcpy(d_cp, cp_len.data(), cp_len.size() * sizeof(unsigned), cudaMemcpyHostToDevice));
      CK(cudaMalloc(&d_start, sym_start.size() * sizeof(unsigned)));
      CK(cudaMemcpy(d_start, sym_start.data(), sym_start.size() * sizeof(unsigned), cudaMemcpyHostToDevice));
      auto plan = lowphy_ofdm_plan_create(dft, ports, NOF_SYMBOLS, true);
      lowphy_ofdm_mod_params mod{};
      mod.plan = plan; mod.grid = d_port; mod.out = d_ci16; mod.port_empty = nullptr;
      mod.phase = d_phase; mod.cp_len = d_cp; mod.symbol_start = d_start;
      mod.nof_ports = ports; mod.nof_symbols_per_slot = NOF_SYMBOLS; mod.dft_size = dft;
      mod.bw_rb = p.bw_rb; mod.slot_index = 0; mod.slot_start = 0; mod.slot_samples = slot_samples; mod.scale = 1.0f;

      auto run = [&]() {
        CK(cudaMemcpyAsync(d_comp, h_comp.data(), comp_bytes, cudaMemcpyHostToDevice, stream));
        lowphy_bfp_decompress(d_comp, d_dec, layers, NOF_SYMBOLS, p.bw_rb, DATA_WIDTH, stream);
        lowphy_catb_precode(d_dec, d_w, d_port, layers, ports, NOF_SYMBOLS, p.bw_rb, stream);
        lowphy_ofdm_mod_pre(mod, stream);
        lowphy_ofdm_mod_fft(mod, stream);
        lowphy_ofdm_mod_post(mod, stream);
      };
      std::vector<ocudu::ci16_t> gpu(static_cast<size_t>(ports) * slot_samples);
      run();
      CK(cudaMemcpyAsync(gpu.data(), d_ci16, ci16_bytes, cudaMemcpyDeviceToHost, stream));
      CK(cudaStreamSynchronize(stream));

      size_t max_lsb = 0;
      double err = 0, sig = 0;
      for (size_t i = 0; i != gpu.size(); ++i) {
        const long d = static_cast<long>(gpu[i].real()) - golden[i].real();
        max_lsb = std::max(max_lsb, static_cast<size_t>(std::llabs(d)));
        err += static_cast<double>(d) * d;
        sig += static_cast<double>(golden[i].real()) * golden[i].real();
      }
      const double err_db = (sig > 0) ? 10.0 * std::log10(err / sig) : -300.0;
      const bool pass = max_lsb <= 1 && err_db <= -60.0;
      all_pass = all_pass && pass;

      for (unsigned i = 0; i != WARMUP; ++i) run();
      std::vector<double> h2d, comp, d2h, e2e;
      h2d.reserve(iters); comp.reserve(iters); d2h.reserve(iters); e2e.reserve(iters);
      for (unsigned i = 0; i != iters; ++i) {
        CK(cudaEventRecord(e_h0, stream));
        CK(cudaMemcpyAsync(d_comp, h_comp.data(), comp_bytes, cudaMemcpyHostToDevice, stream));
        CK(cudaEventRecord(e_h1, stream));
        lowphy_bfp_decompress(d_comp, d_dec, layers, NOF_SYMBOLS, p.bw_rb, DATA_WIDTH, stream);
        lowphy_catb_precode(d_dec, d_w, d_port, layers, ports, NOF_SYMBOLS, p.bw_rb, stream);
        lowphy_ofdm_mod_pre(mod, stream); lowphy_ofdm_mod_fft(mod, stream); lowphy_ofdm_mod_post(mod, stream);
        CK(cudaEventRecord(e_c1, stream));
        CK(cudaMemcpyAsync(gpu.data(), d_ci16, ci16_bytes, cudaMemcpyDeviceToHost, stream));
        CK(cudaEventRecord(e_d1, stream));
        CK(cudaEventSynchronize(e_d1));
        float ms;
        CK(cudaEventElapsedTime(&ms, e_h0, e_h1)); h2d.push_back(ms);
        CK(cudaEventElapsedTime(&ms, e_h1, e_c1)); comp.push_back(ms);
        CK(cudaEventElapsedTime(&ms, e_c1, e_d1)); d2h.push_back(ms);
        CK(cudaEventElapsedTime(&ms, e_h0, e_d1)); e2e.push_back(ms);
      }
      auto H = compute_stats(h2d), C = compute_stats(comp), D = compute_stats(d2h), E = compute_stats(e2e);
      std::printf("%-7s p=%u layers=%u H2D %.4f/%.4f C %.4f/%.4f D2H %.4f/%.4f E2E %.4f/%.4f %s\n",
                  p.name, ports, layers, H.p50, H.p99, C.p50, C.p99, D.p50, D.p99, E.p50, E.p99,
                  pass ? "PASS" : "FAIL");
      out << p.name << "," << (p.bw_rb == 51 ? 20 : p.bw_rb == 106 ? 40 : 100) << "," << ports << "," << layers
          << ",chain," << H.p50 << "," << H.p99 << "," << C.p50 << "," << C.p99 << ","
          << D.p50 << "," << D.p99 << "," << E.p50 << "," << E.p99 << ","
          << (pass ? "PASS" : "FAIL") << ",max_lsb=" << max_lsb << ";err_db=" << err_db << "\n";

      lowphy_ofdm_plan_destroy(plan);
      cudaFree(d_comp); cudaFree(d_dec); cudaFree(d_port); cudaFree(d_ci16);
      cudaFree(d_w); cudaFree(d_phase); cudaFree(d_cp); cudaFree(d_start);
    }
  }
  cudaEventDestroy(e_h0); cudaEventDestroy(e_h1); cudaEventDestroy(e_c1); cudaEventDestroy(e_d1);
  cudaStreamDestroy(stream);
  std::printf("\nOverall: %s\nCSV: %s\n", all_pass ? "PASS" : "FAIL", csv.c_str());
  return all_pass ? 0 : 1;
}
