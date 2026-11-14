// SPDX-FileCopyrightText: Copyright (C) 2026 Software Radio Systems Limited
// SPDX-License-Identifier: BSD-3-Clause-Open-MPI

#include "lowphy_precoding.h"

namespace {

constexpr unsigned NOF_SC_PER_PRB = 12;
constexpr unsigned THREADS        = 256;

__device__ __forceinline__ float bf16_to_float(uint16_t bits)
{
  return __uint_as_float(static_cast<uint32_t>(bits) << 16);
}

__device__ __forceinline__ uint16_t float_to_bf16(float value)
{
  uint32_t bits = __float_as_uint(value);
  bits += 0x7fffu + ((bits >> 16) & 1u);
  return static_cast<uint16_t>(bits >> 16);
}

/// One thread per (port, symbol, RE). Matches OCUDU generic accumulation order
/// (channel_precoder_generic.cpp:21-29): first layer then accumulate.
__global__ void catb_precode_kernel(const uint16_t* __restrict__ grid_in,
                                    const lowphy_cf32* __restrict__ weights,
                                    uint16_t* __restrict__ grid_out,
                                    unsigned nof_layers,
                                    unsigned nof_ports,
                                    unsigned nof_symbols,
                                    unsigned nof_prbs)
{
  const unsigned nof_subc = nof_prbs * NOF_SC_PER_PRB;
  const unsigned n        = nof_ports * nof_symbols * nof_subc;
  const unsigned idx      = blockIdx.x * blockDim.x + threadIdx.x;
  if (idx >= n) {
    return;
  }

  const unsigned re      = idx % nof_subc;
  const unsigned tmp     = idx / nof_subc;
  const unsigned symbol  = tmp % nof_symbols;
  const unsigned port    = tmp / nof_symbols;
  const unsigned prb     = re / NOF_SC_PER_PRB;

  float sum_re = 0.0f;
  float sum_im = 0.0f;
  for (unsigned layer = 0; layer != nof_layers; ++layer) {
    const size_t in_base =
        ((static_cast<size_t>(layer) * nof_symbols + symbol) * nof_subc + re) * 2u;
    const float in_re = bf16_to_float(grid_in[in_base]);
    const float in_im = bf16_to_float(grid_in[in_base + 1]);
    const lowphy_cf32 w =
        weights[(static_cast<size_t>(prb) * nof_ports + port) * nof_layers + layer];
    // (in_re + j in_im) * (w.re + j w.im)
    sum_re += in_re * w.re - in_im * w.im;
    sum_im += in_re * w.im + in_im * w.re;
  }

  const size_t out_base =
      ((static_cast<size_t>(port) * nof_symbols + symbol) * nof_subc + re) * 2u;
  grid_out[out_base]     = float_to_bf16(sum_re);
  grid_out[out_base + 1] = float_to_bf16(sum_im);
}

/// UL combining with W^H: layer = sum_port conj(W[port,layer]) * y[port].
__global__ void catb_combine_kernel(const lowphy_cf32* __restrict__ grid_in,
                                    const lowphy_cf32* __restrict__ weights,
                                    uint16_t* __restrict__ grid_out,
                                    unsigned nof_layers,
                                    unsigned nof_ports,
                                    unsigned nof_symbols,
                                    unsigned nof_prbs)
{
  const unsigned nof_subc = nof_prbs * NOF_SC_PER_PRB;
  const unsigned n        = nof_layers * nof_symbols * nof_subc;
  const unsigned idx      = blockIdx.x * blockDim.x + threadIdx.x;
  if (idx >= n) {
    return;
  }

  const unsigned re     = idx % nof_subc;
  const unsigned tmp    = idx / nof_subc;
  const unsigned symbol = tmp % nof_symbols;
  const unsigned layer  = tmp / nof_symbols;
  const unsigned prb    = re / NOF_SC_PER_PRB;

  float sum_re = 0.0f;
  float sum_im = 0.0f;
  for (unsigned port = 0; port != nof_ports; ++port) {
    const lowphy_cf32 y =
        grid_in[(static_cast<size_t>(port) * nof_symbols + symbol) * nof_subc + re];
    const lowphy_cf32 w =
        weights[(static_cast<size_t>(prb) * nof_ports + port) * nof_layers + layer];
    // y * conj(w) = (y.re + j y.im) * (w.re - j w.im)
    sum_re += y.re * w.re + y.im * w.im;
    sum_im += y.im * w.re - y.re * w.im;
  }

  const size_t out_base =
      ((static_cast<size_t>(layer) * nof_symbols + symbol) * nof_subc + re) * 2u;
  grid_out[out_base]     = float_to_bf16(sum_re);
  grid_out[out_base + 1] = float_to_bf16(sum_im);
}

} // namespace

void lowphy_catb_precode(const uint16_t*    grid_in,
                         const lowphy_cf32* weights,
                         uint16_t*          grid_out,
                         unsigned           nof_layers,
                         unsigned           nof_ports,
                         unsigned           nof_symbols,
                         unsigned           nof_prbs,
                         cudaStream_t       stream)
{
  const unsigned n      = nof_ports * nof_symbols * nof_prbs * NOF_SC_PER_PRB;
  const unsigned blocks = (n + THREADS - 1) / THREADS;
  catb_precode_kernel<<<blocks, THREADS, 0, stream>>>(
      grid_in, weights, grid_out, nof_layers, nof_ports, nof_symbols, nof_prbs);
}

void lowphy_catb_combine(const lowphy_cf32* grid_in,
                         const lowphy_cf32* weights,
                         uint16_t*          grid_out,
                         unsigned           nof_layers,
                         unsigned           nof_ports,
                         unsigned           nof_symbols,
                         unsigned           nof_prbs,
                         cudaStream_t       stream)
{
  const unsigned n      = nof_layers * nof_symbols * nof_prbs * NOF_SC_PER_PRB;
  const unsigned blocks = (n + THREADS - 1) / THREADS;
  catb_combine_kernel<<<blocks, THREADS, 0, stream>>>(
      grid_in, weights, grid_out, nof_layers, nof_ports, nof_symbols, nof_prbs);
}
