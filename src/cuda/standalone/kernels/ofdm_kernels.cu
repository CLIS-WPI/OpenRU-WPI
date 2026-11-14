// SPDX-FileCopyrightText: Copyright (C) 2026 Software Radio Systems Limited
// SPDX-License-Identifier: BSD-3-Clause-Open-MPI

#include "lowphy_cuda.h"

namespace {

constexpr unsigned THREADS_PER_BLOCK = 256;

__device__ __forceinline__ float bf16_to_float(uint16_t value)
{
  return __uint_as_float(static_cast<uint32_t>(value) << 16);
}

__device__ __forceinline__ int16_t to_ci16(float value)
{
  int quantized = __float2int_rn(value * 32767.0f);
  quantized     = max(-32768, min(32767, quantized));
  return static_cast<int16_t>(quantized);
}

__device__ __forceinline__ lowphy_cf32 cf_add(lowphy_cf32 a, lowphy_cf32 b)
{
  return {a.re + b.re, a.im + b.im};
}

__device__ __forceinline__ lowphy_cf32 cf_sub(lowphy_cf32 a, lowphy_cf32 b)
{
  return {a.re - b.re, a.im - b.im};
}

/// Complex multiplication using the same fused operations as ocudu_simd_cf_prod.
__device__ __forceinline__ lowphy_cf32 cf_mul(lowphy_cf32 a, lowphy_cf32 b)
{
  lowphy_cf32 result;
  result.re = __fmaf_rn(a.re, b.re, -__fmul_rn(a.im, b.im));
  result.im = __fmaf_rn(a.re, b.im, __fmul_rn(a.im, b.re));
  return result;
}

/// Runs the radix-2 decimation-in-time butterfly stages.
///
/// The shared buffer must already contain the input in bit-reversed order.
__device__ void fft_stages(lowphy_cf32* s, unsigned n, unsigned logn, const lowphy_cf32* twiddles)
{
  __syncthreads();

  for (unsigned len = 2; len <= n; len <<= 1) {
    unsigned half = len >> 1;
    unsigned step = n / len;

    for (unsigned butterfly = threadIdx.x; butterfly < (n >> 1); butterfly += blockDim.x) {
      unsigned group = butterfly / half;
      unsigned j     = butterfly - group * half;
      unsigned i0    = group * len + j;
      unsigned i1    = i0 + half;

      lowphy_cf32 w = twiddles[j * step];
      lowphy_cf32 u = s[i0];
      lowphy_cf32 v = cf_mul(w, s[i1]);

      s[i0] = cf_add(u, v);
      s[i1] = cf_sub(u, v);
    }

    __syncthreads();
  }
}

__device__ __forceinline__ unsigned bit_reverse(unsigned value, unsigned logn)
{
  return __brev(value) >> (32 - logn);
}

__global__ void ofdm_modulate_kernel(lowphy_ofdm_mod_params params)
{
  extern __shared__ __align__(16) unsigned char smem_raw[];
  lowphy_cf32* s = reinterpret_cast<lowphy_cf32*>(smem_raw);

  const unsigned port      = blockIdx.x;
  const unsigned sym_slot  = blockIdx.y;
  const unsigned dft_size  = params.dft_size;
  const unsigned bw_size   = params.bw_rb * 12;
  const unsigned half      = bw_size / 2;
  const unsigned sym_sf    = params.slot_index * params.nof_symbols_per_slot + sym_slot;
  const unsigned cp_len    = params.cp_len[sym_sf];
  const unsigned local_off = params.symbol_start[sym_sf] - params.slot_start;
  const unsigned out_base  = port * params.slot_samples + local_off;

  if ((params.port_empty != nullptr) && (params.port_empty[port] != 0)) {
    for (unsigned n = threadIdx.x; n < cp_len + dft_size; n += blockDim.x) {
      params.out[(out_base + n) * 2]     = 0;
      params.out[(out_base + n) * 2 + 1] = 0;
    }
    return;
  }

  const uint16_t* grid_base = params.grid + ((port * params.nof_symbols_per_slot + sym_slot) * bw_size * 2);

  for (unsigned i = threadIdx.x; i < dft_size; i += blockDim.x) {
    lowphy_cf32 value = {0.0f, 0.0f};
    unsigned    subc  = 0;

    if (i < half) {
      subc = half + i;
    } else if (i >= dft_size - half) {
      subc = i - (dft_size - half);
    } else {
      s[bit_reverse(i, params.logn)] = value;
      continue;
    }

    value.re = bf16_to_float(grid_base[subc * 2]);
    value.im = bf16_to_float(grid_base[subc * 2 + 1]);

    s[bit_reverse(i, params.logn)] = value;
  }

  fft_stages(s, dft_size, params.logn, params.twiddles);

  lowphy_cf32 h;
  h.re = params.phase[sym_sf].re * params.scale;
  h.im = params.phase[sym_sf].im * params.scale;

  for (unsigned n = threadIdx.x; n < dft_size; n += blockDim.x) {
    lowphy_cf32 value = cf_mul(s[n], h);
    params.out[(out_base + cp_len + n) * 2]     = to_ci16(value.re);
    params.out[(out_base + cp_len + n) * 2 + 1] = to_ci16(value.im);
  }

  for (unsigned n = threadIdx.x; n < cp_len; n += blockDim.x) {
    lowphy_cf32 value = cf_mul(s[dft_size - cp_len + n], h);
    params.out[(out_base + n) * 2]     = to_ci16(value.re);
    params.out[(out_base + n) * 2 + 1] = to_ci16(value.im);
  }
}

__global__ void ofdm_demodulate_kernel(lowphy_ofdm_demod_params params)
{
  extern __shared__ __align__(16) unsigned char smem_raw[];
  lowphy_cf32* s = reinterpret_cast<lowphy_cf32*>(smem_raw);

  const unsigned port      = blockIdx.x;
  const unsigned sym_slot  = blockIdx.y;
  const unsigned dft_size  = params.dft_size;
  const unsigned bw_size   = params.bw_rb * 12;
  const unsigned half      = bw_size / 2;
  const unsigned sym_sf    = params.slot_index * params.nof_symbols_per_slot + sym_slot;
  const unsigned cp_len    = params.cp_len[sym_sf];
  const unsigned local_off = params.symbol_start[sym_sf] - params.slot_start;
  const unsigned in_base   = port * params.slot_samples + local_off + cp_len - params.window_offset;
  const float    inv_scale = 1.0f / 32767.0f;

  for (unsigned n = threadIdx.x; n < dft_size; n += blockDim.x) {
    lowphy_cf32 value;
    value.re = static_cast<float>(params.in[(in_base + n) * 2]) * inv_scale;
    value.im = static_cast<float>(params.in[(in_base + n) * 2 + 1]) * inv_scale;

    s[bit_reverse(n, params.logn)] = value;
  }

  fft_stages(s, dft_size, params.logn, params.twiddles);

  lowphy_cf32 h;
  h.re = params.phase[sym_sf].re * params.scale;
  h.im = params.phase[sym_sf].im * params.scale;

  lowphy_cf32* grid_base = params.grid + ((port * params.nof_symbols_per_slot + sym_slot) * bw_size);

  for (unsigned i = threadIdx.x; i < dft_size; i += blockDim.x) {
    unsigned subc = 0;

    if (i < half) {
      subc = half + i;
    } else if (i >= dft_size - half) {
      subc = i - (dft_size - half);
    } else {
      continue;
    }

    lowphy_cf32 value = cf_mul(s[i], h);

    if (params.window_phase != nullptr) {
      value = cf_mul(value, params.window_phase[i]);
    }

    grid_base[subc] = value;
  }
}

} // namespace

void lowphy_ofdm_modulate(const lowphy_ofdm_mod_params& params, cudaStream_t stream)
{
  dim3 grid_dim(params.nof_ports, params.nof_symbols_per_slot);
  ofdm_modulate_kernel<<<grid_dim, THREADS_PER_BLOCK, params.dft_size * sizeof(lowphy_cf32), stream>>>(params);
}

void lowphy_ofdm_demodulate(const lowphy_ofdm_demod_params& params, cudaStream_t stream)
{
  dim3 grid_dim(params.nof_ports, params.nof_symbols_per_slot);
  ofdm_demodulate_kernel<<<grid_dim, THREADS_PER_BLOCK, params.dft_size * sizeof(lowphy_cf32), stream>>>(params);
}
