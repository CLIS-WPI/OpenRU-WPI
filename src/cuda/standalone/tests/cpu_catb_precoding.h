// SPDX-FileCopyrightText: Copyright (C) 2026 Software Radio Systems Limited
// SPDX-License-Identifier: BSD-3-Clause-Open-MPI
#pragma once

/// Category-B CPU precoding / combining for the scaling harness.
///
/// Production call pattern (cited):
///   lib/phy/support/resource_grid_mapper_impl.cpp:245-263
///     for each PRG:
///       prg_weights = precoding.get_prg_coefficients(i_prg);   // pre-stored
///       re_buffer_reader_view / writer_view over contiguous REs
///       precoder->apply_precoding(output_re_prg, input_re_prg, prg_weights);
///   Weights are stored once in precoding_configuration
///   (include/ocudu/phy/support/precoding_configuration.h:221-238).
///
/// OCUDU channel_precoder caps ports at MAX_NOF_PORTS=4
/// (include/ocudu/ran/precoding/precoding_constants.h:24). For more ports the
/// harness applies the same OCUDU AVX-512 kernel in 4-port blocks so the whole
/// curve is one implementation. The scalar path is correctness-only.

#include "ocudu/adt/bf16.h"
#include "ocudu/adt/complex.h"
#include "ocudu/phy/generic_functions/precoding/channel_precoder.h"
#include "ocudu/phy/support/re_buffer.h"
#include "ocudu/ran/precoding/precoding_constants.h"
#include "ocudu/ran/precoding/precoding_weight_matrix.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <immintrin.h>
#include <vector>

namespace cpu_catb {

constexpr unsigned NOF_SC_PER_PRB       = 12;
constexpr unsigned NOF_SYMBOLS_PER_SLOT = 14;
constexpr unsigned AVX512_CF            = 8;

inline ocudu::cbf16_t cf_to_cbf16(ocudu::cf_t value) { return ocudu::cbf16_t(value); }

inline void layers_cbf16_to_cf(std::vector<ocudu::cf_t>&             out,
                               const std::vector<ocudu::cbf16_t>&     in,
                               unsigned                              nof_layers,
                               unsigned                              nof_subc)
{
  out.resize(static_cast<size_t>(nof_layers) * NOF_SYMBOLS_PER_SLOT * nof_subc);
  for (size_t i = 0; i != out.size(); ++i) {
    out[i] = ocudu::to_cf(in[i]);
  }
}

/// Pre-built Cat-B weights. Matrices are built once (like precoding_configuration),
/// never rebuilt inside the timed apply loop.
struct WeightBank {
  unsigned nof_prbs   = 0;
  unsigned nof_ports  = 0;
  unsigned nof_layers = 0;

  std::vector<ocudu::cf_t> flat;

  /// One matrix per PRB for the full port count when ports ≤ 4.
  std::vector<ocudu::precoding_weight_matrix> mats;

  /// For ports > 4: mats_blocks[block][prb] covering ports [block*4, …).
  std::vector<std::vector<ocudu::precoding_weight_matrix>> mats_blocks;

  void build(const std::vector<ocudu::cf_t>& weights_prb_port_layer,
             unsigned                        nof_prbs_,
             unsigned                        nof_ports_,
             unsigned                        nof_layers_)
  {
    nof_prbs   = nof_prbs_;
    nof_ports  = nof_ports_;
    nof_layers = nof_layers_;
    flat       = weights_prb_port_layer;
    mats.clear();
    mats_blocks.clear();

    if (nof_layers > ocudu::precoding_constants::MAX_NOF_LAYERS) {
      return;
    }

    if (nof_ports <= ocudu::precoding_constants::MAX_NOF_PORTS) {
      mats.reserve(nof_prbs);
      for (unsigned prb = 0; prb != nof_prbs; ++prb) {
        ocudu::precoding_weight_matrix mat(nof_layers, nof_ports);
        for (unsigned port = 0; port != nof_ports; ++port) {
          for (unsigned layer = 0; layer != nof_layers; ++layer) {
            mat.set_coefficient(flat[(static_cast<size_t>(prb) * nof_ports + port) * nof_layers + layer],
                                layer,
                                port);
          }
        }
        mats.push_back(mat);
      }
      return;
    }

    const unsigned nof_blocks = (nof_ports + 3u) / 4u;
    mats_blocks.resize(nof_blocks);
    for (unsigned b = 0; b != nof_blocks; ++b) {
      const unsigned port_base = b * 4u;
      const unsigned block_n   = std::min(4u, nof_ports - port_base);
      mats_blocks[b].reserve(nof_prbs);
      for (unsigned prb = 0; prb != nof_prbs; ++prb) {
        ocudu::precoding_weight_matrix mat(nof_layers, block_n);
        for (unsigned p = 0; p != block_n; ++p) {
          for (unsigned layer = 0; layer != nof_layers; ++layer) {
            mat.set_coefficient(
                flat[(static_cast<size_t>(prb) * nof_ports + port_base + p) * nof_layers + layer],
                layer,
                p);
          }
        }
        mats_blocks[b].push_back(mat);
      }
    }
  }
};

/// Scalar reference — channel_precoder_generic.cpp:9-30. Correctness only.
inline void precode_reference(std::vector<ocudu::cbf16_t>&       out_ports,
                              const std::vector<ocudu::cf_t>&    in_layers_cf,
                              const WeightBank&                  bank)
{
  const unsigned nof_subc = bank.nof_prbs * NOF_SC_PER_PRB;
  out_ports.assign(static_cast<size_t>(bank.nof_ports) * NOF_SYMBOLS_PER_SLOT * nof_subc, ocudu::cbf16_t(0.0f, 0.0f));
  for (unsigned symbol = 0; symbol != NOF_SYMBOLS_PER_SLOT; ++symbol) {
    for (unsigned port = 0; port != bank.nof_ports; ++port) {
      for (unsigned re = 0; re != nof_subc; ++re) {
        const unsigned prb = re / NOF_SC_PER_PRB;
        ocudu::cf_t    sum = ocudu::cf_t(0.0f, 0.0f);
        for (unsigned layer = 0; layer != bank.nof_layers; ++layer) {
          const ocudu::cf_t in =
              in_layers_cf[(static_cast<size_t>(layer) * NOF_SYMBOLS_PER_SLOT + symbol) * nof_subc + re];
          const ocudu::cf_t w =
              bank.flat[(static_cast<size_t>(prb) * bank.nof_ports + port) * bank.nof_layers + layer];
          sum += in * w;
        }
        out_ports[(static_cast<size_t>(port) * NOF_SYMBOLS_PER_SLOT + symbol) * nof_subc + re] = cf_to_cbf16(sum);
      }
    }
  }
}

inline void combine_reference(std::vector<ocudu::cbf16_t>&    out_layers,
                              const std::vector<ocudu::cf_t>& in_ports_cf,
                              const WeightBank&               bank)
{
  const unsigned nof_subc = bank.nof_prbs * NOF_SC_PER_PRB;
  out_layers.assign(static_cast<size_t>(bank.nof_layers) * NOF_SYMBOLS_PER_SLOT * nof_subc, ocudu::cbf16_t(0.0f, 0.0f));
  for (unsigned symbol = 0; symbol != NOF_SYMBOLS_PER_SLOT; ++symbol) {
    for (unsigned layer = 0; layer != bank.nof_layers; ++layer) {
      for (unsigned re = 0; re != nof_subc; ++re) {
        const unsigned prb = re / NOF_SC_PER_PRB;
        ocudu::cf_t    sum = ocudu::cf_t(0.0f, 0.0f);
        for (unsigned port = 0; port != bank.nof_ports; ++port) {
          const ocudu::cf_t y =
              in_ports_cf[(static_cast<size_t>(port) * NOF_SYMBOLS_PER_SLOT + symbol) * nof_subc + re];
          const ocudu::cf_t w =
              bank.flat[(static_cast<size_t>(prb) * bank.nof_ports + port) * bank.nof_layers + layer];
          sum += y * std::conj(w);
        }
        out_layers[(static_cast<size_t>(layer) * NOF_SYMBOLS_PER_SLOT + symbol) * nof_subc + re] = cf_to_cbf16(sum);
      }
    }
  }
}

#if defined(__AVX512F__)

struct simd_cf {
  __m512 re;
  __m512 im;
  void   set1(ocudu::cf_t a)
  {
    re = _mm512_set1_ps(a.real());
    im = _mm512_set1_ps(a.imag());
  }
};

/// Mirrors channel_precoder_avx512.cpp:58-60.
inline __m512 cmul(__m512 a, simd_cf w)
{
  return _mm512_fmaddsub_ps(a, w.re, _mm512_mul_ps(_mm512_shuffle_ps(a, a, 0xb1), w.im));
}

inline __m256i ps_to_cbf16(__m512 in)
{
  const __m512i bias = _mm512_set1_epi32(0x7fff);
  const __m512i one  = _mm512_set1_epi32(0x1);
  __m512i       a    = _mm512_castps_si512(in);
  a                  = _mm512_add_epi32(a, _mm512_add_epi32(bias, _mm512_and_si512(_mm512_srli_epi32(a, 16), one)));
  a                  = _mm512_srli_epi32(a, 16);
  return _mm512_cvtepi32_epi16(a);
}

/// One symbol: for each PRB load layer REs once, then apply all ports.
/// Math matches channel_precoder_avx512.cpp:221-269; Cat-B weight per PRB.
/// Avoids 273×14 virtual apply_precoding(12 RE) calls and reloads layer data once per PRB.
inline void precode_symbol_avx512(ocudu::cbf16_t**          out_ports,
                                  const ocudu::cf_t* const* layer_ptrs,
                                  unsigned                  nof_layers,
                                  unsigned                  nof_ports,
                                  unsigned                  nof_prbs,
                                  const ocudu::cf_t*        flat_weights)
{
  for (unsigned prb = 0; prb != nof_prbs; ++prb) {
    const unsigned re0 = prb * NOF_SC_PER_PRB;
    // 12 REs: AVX-512 ×8 + AVX2 ×4 (4 complex = 8 floats).
    __m512 layer8[4];
    __m256 layer4[4];
    for (unsigned layer = 0; layer != nof_layers; ++layer) {
      layer8[layer] = _mm512_loadu_ps(reinterpret_cast<const float*>(&layer_ptrs[layer][re0]));
      layer4[layer] = _mm256_loadu_ps(reinterpret_cast<const float*>(&layer_ptrs[layer][re0 + 8]));
    }
    for (unsigned port = 0; port != nof_ports; ++port) {
      const ocudu::cf_t* wrow =
          &flat_weights[(static_cast<size_t>(prb) * nof_ports + port) * nof_layers];
      simd_cf w0;
      w0.set1(wrow[0]);
      __m512 out8 = cmul(layer8[0], w0);
      __m256 out4 = _mm256_fmaddsub_ps(
          layer4[0],
          _mm256_set1_ps(wrow[0].real()),
          _mm256_mul_ps(_mm256_shuffle_ps(layer4[0], layer4[0], 0xb1), _mm256_set1_ps(wrow[0].imag())));
      for (unsigned layer = 1; layer != nof_layers; ++layer) {
        simd_cf w;
        w.set1(wrow[layer]);
        out8 = _mm512_add_ps(out8, cmul(layer8[layer], w));
        out4 = _mm256_add_ps(
            out4,
            _mm256_fmaddsub_ps(
                layer4[layer],
                _mm256_set1_ps(wrow[layer].real()),
                _mm256_mul_ps(_mm256_shuffle_ps(layer4[layer], layer4[layer], 0xb1),
                              _mm256_set1_ps(wrow[layer].imag()))));
      }
      _mm256_storeu_si256(reinterpret_cast<__m256i*>(&out_ports[port][re0]), ps_to_cbf16(out8));
      // Convert 4 complex floats → 4 cbf16 (same rounding as ps_to_cbf16).
      alignas(32) float tmp[8];
      _mm256_store_ps(tmp, out4);
      for (unsigned k = 0; k != 4; ++k) {
        out_ports[port][re0 + 8 + k] = cf_to_cbf16(ocudu::cf_t(tmp[2 * k], tmp[2 * k + 1]));
      }
    }
  }
}

inline void combine_layer_avx512(ocudu::cbf16_t*                 out,
                                 const std::vector<ocudu::cf_t*>& port_ptrs,
                                 unsigned                        nof_ports,
                                 unsigned                        nof_re,
                                 unsigned                        layer,
                                 unsigned                        nof_layers,
                                 const ocudu::cf_t*              flat_weights)
{
  for (unsigned re0 = 0; re0 < nof_re; re0 += NOF_SC_PER_PRB) {
    const unsigned prb    = re0 / NOF_SC_PER_PRB;
    const unsigned n_here = std::min(NOF_SC_PER_PRB, nof_re - re0);
    const unsigned n_avx  = (n_here / AVX512_CF) * AVX512_CF;

    unsigned i = 0;
    for (; i != n_avx; i += AVX512_CF) {
      __m512 re_out = _mm512_setzero_ps();
      for (unsigned port = 0; port != nof_ports; ++port) {
        ocudu::cf_t w = flat_weights[(static_cast<size_t>(prb) * nof_ports + port) * nof_layers + layer];
        simd_cf     wc;
        wc.set1(ocudu::cf_t(w.real(), -w.imag()));
        __m512 yin = _mm512_loadu_ps(reinterpret_cast<const float*>(&port_ptrs[port][re0 + i]));
        re_out     = _mm512_add_ps(re_out, cmul(yin, wc));
      }
      _mm256_storeu_si256(reinterpret_cast<__m256i*>(&out[re0 + i]), ps_to_cbf16(re_out));
    }
    for (; i != n_here; ++i) {
      ocudu::cf_t sum = ocudu::cf_t(0.0f, 0.0f);
      for (unsigned port = 0; port != nof_ports; ++port) {
        const ocudu::cf_t w =
            flat_weights[(static_cast<size_t>(prb) * nof_ports + port) * nof_layers + layer];
        sum += port_ptrs[port][re0 + i] * std::conj(w);
      }
      out[re0 + i] = cf_to_cbf16(sum);
    }
  }
}

#endif // __AVX512F__

/// OCUDU production call pattern for ports ≤ 4 (and 4-port blocks when > 4):
/// resource_grid_mapper_impl.cpp:245-263 — pre-stored weights + RE views.
/// Kept for API fidelity checks; Cat-B with 1-PRB PRGs pays per-call overhead on 12 REs.
inline void precode_ocudu_prg_views(std::vector<ocudu::cbf16_t>&       out_ports,
                                    const std::vector<ocudu::cf_t>&    in_layers_cf,
                                    const WeightBank&                  bank,
                                    ocudu::channel_precoder*           ocudu_precoder)
{
  const unsigned nof_subc = bank.nof_prbs * NOF_SC_PER_PRB;
  out_ports.resize(static_cast<size_t>(bank.nof_ports) * NOF_SYMBOLS_PER_SLOT * nof_subc);
  if (ocudu_precoder == nullptr || bank.nof_layers > ocudu::precoding_constants::MAX_NOF_LAYERS) {
    precode_reference(out_ports, in_layers_cf, bank);
    return;
  }

  using layer_mod_t = ocudu::modular_re_buffer_reader<ocudu::cf_t, ocudu::precoding_constants::MAX_NOF_LAYERS>;
  using port_mod_t  = ocudu::modular_re_buffer<ocudu::cbf16_t, ocudu::precoding_constants::MAX_NOF_PORTS>;
  layer_mod_t in_mod(bank.nof_layers, nof_subc);
  port_mod_t  out_mod(std::min(bank.nof_ports, ocudu::precoding_constants::MAX_NOF_PORTS), nof_subc);

  auto run_symbol_block = [&](unsigned symbol, unsigned port_base, unsigned block_n,
                              const std::vector<ocudu::precoding_weight_matrix>& mats_prb) {
    for (unsigned layer = 0; layer != bank.nof_layers; ++layer) {
      in_mod.set_slice(
          layer,
          ocudu::span<const ocudu::cf_t>(
              in_layers_cf.data() + (static_cast<size_t>(layer) * NOF_SYMBOLS_PER_SLOT + symbol) * nof_subc,
              nof_subc));
    }
    out_mod.resize(block_n, nof_subc);
    for (unsigned p = 0; p != block_n; ++p) {
      out_mod.set_slice(
          p,
          ocudu::span<ocudu::cbf16_t>(
              out_ports.data() + (static_cast<size_t>(port_base + p) * NOF_SYMBOLS_PER_SLOT + symbol) * nof_subc,
              nof_subc));
    }
    for (unsigned prb = 0; prb != bank.nof_prbs; ++prb) {
      ocudu::re_buffer_reader_view                 in_prg(in_mod, prb * NOF_SC_PER_PRB, NOF_SC_PER_PRB);
      ocudu::re_buffer_writer_view<ocudu::cbf16_t> out_prg(out_mod, prb * NOF_SC_PER_PRB, NOF_SC_PER_PRB);
      ocudu_precoder->apply_precoding(out_prg, in_prg, mats_prb[prb]);
    }
  };

  for (unsigned symbol = 0; symbol != NOF_SYMBOLS_PER_SLOT; ++symbol) {
    if (!bank.mats.empty()) {
      run_symbol_block(symbol, 0, bank.nof_ports, bank.mats);
    } else {
      for (unsigned b = 0, nb = static_cast<unsigned>(bank.mats_blocks.size()); b != nb; ++b) {
        const unsigned port_base = b * 4u;
        const unsigned block_n   = std::min(4u, bank.nof_ports - port_base);
        run_symbol_block(symbol, port_base, block_n, bank.mats_blocks[b]);
      }
    }
  }
}

/// Timed Cat-B precoding for one slot — single AVX-512 implementation for all port counts.
/// Math matches OCUDU apply_precoding_port (channel_precoder_avx512.cpp:221-269);
/// weights are pre-stored (WeightBank) like precoding.get_prg_coefficients.
/// Scalar reference remains correctness-only.
inline void precode_optimized(std::vector<ocudu::cbf16_t>&       out_ports,
                              const std::vector<ocudu::cf_t>&    in_layers_cf,
                              const WeightBank&                  bank,
                              ocudu::channel_precoder*           /*ocudu_precoder*/)
{
  const unsigned nof_subc = bank.nof_prbs * NOF_SC_PER_PRB;
  out_ports.resize(static_cast<size_t>(bank.nof_ports) * NOF_SYMBOLS_PER_SLOT * nof_subc);
#if defined(__AVX512F__)
  const ocudu::cf_t* layer_ptrs[ocudu::precoding_constants::MAX_NOF_LAYERS];
  ocudu::cbf16_t*    out_ptrs[64];
  for (unsigned symbol = 0; symbol != NOF_SYMBOLS_PER_SLOT; ++symbol) {
    for (unsigned layer = 0; layer != bank.nof_layers; ++layer) {
      layer_ptrs[layer] =
          in_layers_cf.data() + (static_cast<size_t>(layer) * NOF_SYMBOLS_PER_SLOT + symbol) * nof_subc;
    }
    for (unsigned port = 0; port != bank.nof_ports; ++port) {
      out_ptrs[port] =
          out_ports.data() + (static_cast<size_t>(port) * NOF_SYMBOLS_PER_SLOT + symbol) * nof_subc;
    }
    precode_symbol_avx512(out_ptrs, layer_ptrs, bank.nof_layers, bank.nof_ports, bank.nof_prbs, bank.flat.data());
  }
#else
  precode_reference(out_ports, in_layers_cf, bank);
#endif
}

/// Optimized UL combining (Wᴴ) — AVX-512 over REs for all port counts.
/// OCUDU has no combining API; scalar reference is correctness-only.
inline void combine_optimized(std::vector<ocudu::cbf16_t>&    out_layers,
                              const std::vector<ocudu::cf_t>& in_ports_cf,
                              const WeightBank&               bank)
{
  const unsigned nof_subc = bank.nof_prbs * NOF_SC_PER_PRB;
  out_layers.resize(static_cast<size_t>(bank.nof_layers) * NOF_SYMBOLS_PER_SLOT * nof_subc);
#if defined(__AVX512F__)
  for (unsigned symbol = 0; symbol != NOF_SYMBOLS_PER_SLOT; ++symbol) {
    std::vector<ocudu::cf_t*> port_ptrs(bank.nof_ports);
    for (unsigned port = 0; port != bank.nof_ports; ++port) {
      port_ptrs[port] = const_cast<ocudu::cf_t*>(
          in_ports_cf.data() + (static_cast<size_t>(port) * NOF_SYMBOLS_PER_SLOT + symbol) * nof_subc);
    }
    for (unsigned layer = 0; layer != bank.nof_layers; ++layer) {
      ocudu::cbf16_t* out =
          out_layers.data() + (static_cast<size_t>(layer) * NOF_SYMBOLS_PER_SLOT + symbol) * nof_subc;
      combine_layer_avx512(out, port_ptrs, bank.nof_ports, nof_subc, layer, bank.nof_layers, bank.flat.data());
    }
  }
#else
  combine_reference(out_layers, in_ports_cf, bank);
#endif
}

inline double flop_count_precode(unsigned nof_ports, unsigned nof_layers, unsigned nof_prbs)
{
  // Complex MAC = 6 FLOPs; one MAC per (RE, port, layer).
  return static_cast<double>(NOF_SYMBOLS_PER_SLOT) * nof_prbs * NOF_SC_PER_PRB * nof_ports * nof_layers * 6.0;
}

} // namespace cpu_catb
