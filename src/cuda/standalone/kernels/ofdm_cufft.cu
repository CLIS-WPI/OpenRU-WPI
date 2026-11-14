// SPDX-FileCopyrightText: Copyright (C) 2026 Software Radio Systems Limited
// SPDX-License-Identifier: BSD-3-Clause-Open-MPI

#include "lowphy_cuda.h"

#include <cufft.h>
#include <new>

struct lowphy_ofdm_plan {
  cufftHandle  handle  = 0;
  lowphy_cf32* fft_in  = nullptr;
  lowphy_cf32* fft_out = nullptr;
  unsigned     dft_size = 0;
  unsigned     batch    = 0;
  bool         inverse  = false;
};

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

/// Complex multiplication using the same fused operations as ocudu_simd_cf_prod.
__device__ __forceinline__ lowphy_cf32 cf_mul(lowphy_cf32 a, lowphy_cf32 b)
{
  lowphy_cf32 result;
  result.re = __fmaf_rn(a.re, b.re, -__fmul_rn(a.im, b.im));
  result.im = __fmaf_rn(a.re, b.im, __fmul_rn(a.im, b.re));
  return result;
}

/// Maps a resource grid into the cuFFT input buffer in natural (non bit-reversed) order.
///
/// Low subcarriers are placed at DFT indices [dft_size - half, dft_size), high subcarriers at
/// [0, half), and the unused centre bins are zeroed.
__global__ void ofdm_mod_pre_kernel(lowphy_ofdm_mod_params params, lowphy_cf32* fft_in)
{
  const unsigned port     = blockIdx.x;
  const unsigned sym_slot = blockIdx.y;
  const unsigned dft_size = params.dft_size;
  const unsigned bw_size  = params.bw_rb * 12;
  const unsigned half     = bw_size / 2;

  lowphy_cf32* dst =
      fft_in + (static_cast<size_t>(port) * params.nof_symbols_per_slot + sym_slot) * dft_size;

  const uint16_t* src =
      params.grid + (static_cast<size_t>(port) * params.nof_symbols_per_slot + sym_slot) * bw_size * 2;

  for (unsigned i = threadIdx.x; i < dft_size; i += blockDim.x) {
    lowphy_cf32 value = {0.0f, 0.0f};
    unsigned    subc  = 0;
    bool        used  = false;

    if (i < half) {
      subc = half + i;
      used = true;
    } else if (i >= dft_size - half) {
      subc = i - (dft_size - half);
      used = true;
    }

    if (used) {
      value.re = bf16_to_float(src[subc * 2]);
      value.im = bf16_to_float(src[subc * 2 + 1]);
    }

    dst[i] = value;
  }
}

/// Applies phase compensation and scaling, converts to ci16 and inserts the cyclic prefix.
__global__ void ofdm_mod_post_kernel(lowphy_ofdm_mod_params params, const lowphy_cf32* fft_out)
{
  const unsigned port      = blockIdx.x;
  const unsigned sym_slot  = blockIdx.y;
  const unsigned dft_size  = params.dft_size;
  const unsigned sym_sf    = params.slot_index * params.nof_symbols_per_slot + sym_slot;
  const unsigned cp_len    = params.cp_len[sym_sf];
  const unsigned local_off = params.symbol_start[sym_sf] - params.slot_start;
  int16_t*       out =
      params.out + (static_cast<size_t>(port) * params.slot_samples + local_off) * 2;

  if ((params.port_empty != nullptr) && (params.port_empty[port] != 0)) {
    for (unsigned n = threadIdx.x; n < cp_len + dft_size; n += blockDim.x) {
      out[n * 2]     = 0;
      out[n * 2 + 1] = 0;
    }
    return;
  }

  const lowphy_cf32* src =
      fft_out + (static_cast<size_t>(port) * params.nof_symbols_per_slot + sym_slot) * dft_size;

  lowphy_cf32 h;
  h.re = params.phase[sym_sf].re * params.scale;
  h.im = params.phase[sym_sf].im * params.scale;

  for (unsigned n = threadIdx.x; n < dft_size; n += blockDim.x) {
    lowphy_cf32 value = cf_mul(src[n], h);
    out[(cp_len + n) * 2]     = to_ci16(value.re);
    out[(cp_len + n) * 2 + 1] = to_ci16(value.im);
  }

  for (unsigned n = threadIdx.x; n < cp_len; n += blockDim.x) {
    lowphy_cf32 value = cf_mul(src[dft_size - cp_len + n], h);
    out[n * 2]     = to_ci16(value.re);
    out[n * 2 + 1] = to_ci16(value.im);
  }
}

/// Copies the time-domain samples of one symbol into the cuFFT input buffer, skipping the CP.
__global__ void ofdm_demod_pre_kernel(lowphy_ofdm_demod_params params, lowphy_cf32* fft_in)
{
  const unsigned port      = blockIdx.x;
  const unsigned sym_slot  = blockIdx.y;
  const unsigned dft_size  = params.dft_size;
  const unsigned sym_sf    = params.slot_index * params.nof_symbols_per_slot + sym_slot;
  const unsigned cp_len    = params.cp_len[sym_sf];
  const unsigned local_off = params.symbol_start[sym_sf] - params.slot_start;
  const long     in_base   = static_cast<long>(port) * params.slot_samples + local_off + cp_len -
                         static_cast<long>(params.window_offset);
  const int16_t* src = params.in + in_base * 2;

  lowphy_cf32* dst =
      fft_in + (static_cast<size_t>(port) * params.nof_symbols_per_slot + sym_slot) * dft_size;

  constexpr float inv_scale = 1.0f / 32767.0f;

  for (unsigned n = threadIdx.x; n < dft_size; n += blockDim.x) {
    lowphy_cf32 value;
    value.re = static_cast<float>(src[n * 2]) * inv_scale;
    value.im = static_cast<float>(src[n * 2 + 1]) * inv_scale;
    dst[n]   = value;
  }
}

/// Applies phase compensation and scaling, then maps the DFT bins back into the resource grid.
__global__ void ofdm_demod_post_kernel(lowphy_ofdm_demod_params params, const lowphy_cf32* fft_out)
{
  const unsigned port      = blockIdx.x;
  const unsigned sym_slot  = blockIdx.y;
  const unsigned dft_size  = params.dft_size;
  const unsigned bw_size   = params.bw_rb * 12;
  const unsigned half      = bw_size / 2;
  const unsigned sym_sf    = params.slot_index * params.nof_symbols_per_slot + sym_slot;

  const lowphy_cf32* src =
      fft_out + (static_cast<size_t>(port) * params.nof_symbols_per_slot + sym_slot) * dft_size;
  lowphy_cf32* grid =
      params.grid + (static_cast<size_t>(port) * params.nof_symbols_per_slot + sym_slot) * bw_size;

  lowphy_cf32 h;
  h.re = params.phase[sym_sf].re * params.scale;
  h.im = params.phase[sym_sf].im * params.scale;

  for (unsigned i = threadIdx.x; i < dft_size; i += blockDim.x) {
    unsigned subc = 0;
    bool     used = false;

    if (i < half) {
      subc = half + i;
      used = true;
    } else if (i >= dft_size - half) {
      subc = i - (dft_size - half);
      used = true;
    }

    if (!used) {
      continue;
    }

    lowphy_cf32 value = cf_mul(src[i], h);

    if (params.window_phase != nullptr) {
      value = cf_mul(value, params.window_phase[i]);
    }

    grid[subc] = value;
  }
}

} // namespace

lowphy_ofdm_plan* lowphy_ofdm_plan_create(unsigned dft_size,
                                          unsigned nof_ports,
                                          unsigned nof_symbols_per_slot,
                                          bool     inverse)
{
  auto* plan = new (std::nothrow) lowphy_ofdm_plan();
  if (plan == nullptr) {
    return nullptr;
  }

  plan->dft_size = dft_size;
  plan->batch    = nof_ports * nof_symbols_per_slot;
  plan->inverse  = inverse;

  int         length  = static_cast<int>(dft_size);
  int         embed   = static_cast<int>(dft_size);
  cufftResult result  = cufftPlanMany(
      &plan->handle, 1, &length, &embed, 1, embed, &embed, 1, embed, CUFFT_C2C, static_cast<int>(plan->batch));
  if (result != CUFFT_SUCCESS) {
    delete plan;
    return nullptr;
  }

  const size_t bytes = static_cast<size_t>(plan->batch) * dft_size * sizeof(lowphy_cf32);
  if (cudaMalloc(reinterpret_cast<void**>(&plan->fft_in), bytes) != cudaSuccess) {
    cufftDestroy(plan->handle);
    delete plan;
    return nullptr;
  }

  if (cudaMalloc(reinterpret_cast<void**>(&plan->fft_out), bytes) != cudaSuccess) {
    cudaFree(plan->fft_in);
    cufftDestroy(plan->handle);
    delete plan;
    return nullptr;
  }

  return plan;
}

void lowphy_ofdm_plan_destroy(lowphy_ofdm_plan* plan)
{
  if (plan == nullptr) {
    return;
  }

  if (plan->fft_in != nullptr) {
    cudaFree(plan->fft_in);
  }
  if (plan->fft_out != nullptr) {
    cudaFree(plan->fft_out);
  }
  if (plan->handle != 0) {
    cufftDestroy(plan->handle);
  }

  delete plan;
}

void lowphy_ofdm_mod_pre(const lowphy_ofdm_mod_params& params, cudaStream_t stream)
{
  dim3 grid_dim(params.nof_ports, params.nof_symbols_per_slot);
  ofdm_mod_pre_kernel<<<grid_dim, THREADS_PER_BLOCK, 0, stream>>>(params, params.plan->fft_in);
}

void lowphy_ofdm_mod_fft(const lowphy_ofdm_mod_params& params, cudaStream_t stream)
{
  cufftSetStream(params.plan->handle, stream);
  cufftExecC2C(params.plan->handle,
               reinterpret_cast<cufftComplex*>(params.plan->fft_in),
               reinterpret_cast<cufftComplex*>(params.plan->fft_out),
               CUFFT_INVERSE);
}

void lowphy_ofdm_mod_post(const lowphy_ofdm_mod_params& params, cudaStream_t stream)
{
  dim3 grid_dim(params.nof_ports, params.nof_symbols_per_slot);
  ofdm_mod_post_kernel<<<grid_dim, THREADS_PER_BLOCK, 0, stream>>>(params, params.plan->fft_out);
}

void lowphy_ofdm_demod_pre(const lowphy_ofdm_demod_params& params, cudaStream_t stream)
{
  dim3 grid_dim(params.nof_ports, params.nof_symbols_per_slot);
  ofdm_demod_pre_kernel<<<grid_dim, THREADS_PER_BLOCK, 0, stream>>>(params, params.plan->fft_in);
}

void lowphy_ofdm_demod_fft(const lowphy_ofdm_demod_params& params, cudaStream_t stream)
{
  cufftSetStream(params.plan->handle, stream);
  cufftExecC2C(params.plan->handle,
               reinterpret_cast<cufftComplex*>(params.plan->fft_in),
               reinterpret_cast<cufftComplex*>(params.plan->fft_out),
               CUFFT_FORWARD);
}

void lowphy_ofdm_demod_post(const lowphy_ofdm_demod_params& params, cudaStream_t stream)
{
  dim3 grid_dim(params.nof_ports, params.nof_symbols_per_slot);
  ofdm_demod_post_kernel<<<grid_dim, THREADS_PER_BLOCK, 0, stream>>>(params, params.plan->fft_out);
}
