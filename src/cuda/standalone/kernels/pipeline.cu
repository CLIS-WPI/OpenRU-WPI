// SPDX-FileCopyrightText: Copyright (C) 2026 Software Radio Systems Limited
// SPDX-License-Identifier: BSD-3-Clause-Open-MPI

#include "lowphy_pipeline.h"

#include <cmath>
#include <cstring>

namespace {

constexpr unsigned NOF_SYMBOLS_PER_SLOT = 14;
constexpr unsigned THREADS              = 256;

unsigned packed_prb_bytes(unsigned data_width)
{
  return 1u + ((24u * data_width + 7u) / 8u);
}

__device__ __forceinline__ uint16_t float_to_bf16(float value)
{
  uint32_t bits = __float_as_uint(value);
  bits += 0x7fffu + ((bits >> 16) & 1u);
  return static_cast<uint16_t>(bits >> 16);
}

/// Convert demod cf32 grid → cbf16 grid (same layout [port][symbol][subc]).
__global__ void cf32_to_cbf16_kernel(const lowphy_cf32* in, uint16_t* out, unsigned n_complex)
{
  unsigned i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n_complex) {
    return;
  }
  out[i * 2]     = float_to_bf16(in[i].re);
  out[i * 2 + 1] = float_to_bf16(in[i].im);
}

} // namespace

void lowphy_cf32_to_cbf16(const lowphy_cf32* in, uint16_t* out, unsigned n_complex, cudaStream_t stream)
{
  const unsigned blocks = (n_complex + THREADS - 1) / THREADS;
  cf32_to_cbf16_kernel<<<blocks, THREADS, 0, stream>>>(in, out, n_complex);
}

bool lowphy_pipeline_create(lowphy_pipeline*   pipe,
                            unsigned           nof_ports,
                            unsigned           nof_prbs,
                            unsigned           dft_size,
                            unsigned           bw_rb,
                            unsigned           slot_samples,
                            unsigned           data_width,
                            unsigned           nof_symbols_sf,
                            const lowphy_cf32* phase_mod_host,
                            const lowphy_cf32* phase_demod_host,
                            const unsigned*    cp_len_host,
                            const unsigned*    symbol_start_host)
{
  std::memset(pipe, 0, sizeof(*pipe));
  pipe->nof_ports            = nof_ports;
  pipe->nof_symbols_per_slot = NOF_SYMBOLS_PER_SLOT;
  pipe->nof_prbs             = nof_prbs;
  pipe->data_width           = data_width;
  pipe->dft_size             = dft_size;
  pipe->bw_rb                = bw_rb;
  pipe->slot_samples         = slot_samples;
  pipe->prb_packed_bytes     = packed_prb_bytes(data_width);

  const unsigned rg = bw_rb * 12u;
  pipe->compressed_bytes =
      static_cast<size_t>(nof_ports) * NOF_SYMBOLS_PER_SLOT * nof_prbs * pipe->prb_packed_bytes;
  pipe->cbf16_bytes = static_cast<size_t>(nof_ports) * NOF_SYMBOLS_PER_SLOT * rg * sizeof(uint16_t) * 2u;
  pipe->cf32_bytes  = static_cast<size_t>(nof_ports) * NOF_SYMBOLS_PER_SLOT * rg * sizeof(lowphy_cf32);
  pipe->ci16_bytes  = static_cast<size_t>(nof_ports) * slot_samples * sizeof(int16_t) * 2u;

  pipe->mod_plan   = lowphy_ofdm_plan_create(dft_size, nof_ports, NOF_SYMBOLS_PER_SLOT, true);
  pipe->demod_plan = lowphy_ofdm_plan_create(dft_size, nof_ports, NOF_SYMBOLS_PER_SLOT, false);
  if ((pipe->mod_plan == nullptr) || (pipe->demod_plan == nullptr)) {
    lowphy_pipeline_destroy(pipe);
    return false;
  }

  auto fail = [&](bool bad) {
    if (bad) {
      lowphy_pipeline_destroy(pipe);
    }
    return !bad;
  };

  if (!fail(cudaMalloc(&pipe->d_phase_mod, nof_symbols_sf * sizeof(lowphy_cf32)) != cudaSuccess)) {
    return false;
  }
  if (!fail(cudaMalloc(&pipe->d_phase_demod, nof_symbols_sf * sizeof(lowphy_cf32)) != cudaSuccess)) {
    return false;
  }
  if (!fail(cudaMalloc(&pipe->d_cp_len, nof_symbols_sf * sizeof(unsigned)) != cudaSuccess)) {
    return false;
  }
  if (!fail(cudaMalloc(&pipe->d_symbol_start, nof_symbols_sf * sizeof(unsigned)) != cudaSuccess)) {
    return false;
  }
  if (!fail(cudaMalloc(&pipe->d_port_empty, nof_ports) != cudaSuccess)) {
    return false;
  }

  cudaMemcpy(pipe->d_phase_mod, phase_mod_host, nof_symbols_sf * sizeof(lowphy_cf32), cudaMemcpyHostToDevice);
  cudaMemcpy(pipe->d_phase_demod, phase_demod_host, nof_symbols_sf * sizeof(lowphy_cf32), cudaMemcpyHostToDevice);
  cudaMemcpy(pipe->d_cp_len, cp_len_host, nof_symbols_sf * sizeof(unsigned), cudaMemcpyHostToDevice);
  cudaMemcpy(pipe->d_symbol_start, symbol_start_host, nof_symbols_sf * sizeof(unsigned), cudaMemcpyHostToDevice);
  cudaMemset(pipe->d_port_empty, 0, nof_ports);

  for (unsigned b = 0; b != 2; ++b) {
    if (!fail(cudaMalloc(&pipe->d_compressed[b], pipe->compressed_bytes + 2) != cudaSuccess)) {
      return false;
    }
    if (!fail(cudaMalloc(reinterpret_cast<void**>(&pipe->d_grid_cbf16[b]), pipe->cbf16_bytes) != cudaSuccess)) {
      return false;
    }
    if (!fail(cudaMalloc(reinterpret_cast<void**>(&pipe->d_grid_cf32[b]), pipe->cf32_bytes) != cudaSuccess)) {
      return false;
    }
    if (!fail(cudaMalloc(reinterpret_cast<void**>(&pipe->d_ci16[b]), pipe->ci16_bytes) != cudaSuccess)) {
      return false;
    }
    cudaMemset(pipe->d_compressed[b], 0, pipe->compressed_bytes + 2);
  }
  return true;
}

void lowphy_pipeline_destroy(lowphy_pipeline* pipe)
{
  if (pipe == nullptr) {
    return;
  }
  lowphy_ofdm_plan_destroy(pipe->mod_plan);
  lowphy_ofdm_plan_destroy(pipe->demod_plan);
  pipe->mod_plan = pipe->demod_plan = nullptr;

  auto free_p = [](auto*& p) {
    if (p != nullptr) {
      cudaFree(p);
      p = nullptr;
    }
  };
  free_p(pipe->d_phase_mod);
  free_p(pipe->d_phase_demod);
  free_p(pipe->d_cp_len);
  free_p(pipe->d_symbol_start);
  free_p(pipe->d_port_empty);
  for (unsigned b = 0; b != 2; ++b) {
    free_p(pipe->d_compressed[b]);
    free_p(pipe->d_grid_cbf16[b]);
    free_p(pipe->d_grid_cf32[b]);
    free_p(pipe->d_ci16[b]);
  }
}

void lowphy_pipeline_dl(lowphy_pipeline* pipe,
                        unsigned         buf,
                        unsigned         slot_index,
                        unsigned         slot_start,
                        const uint8_t*   h_compressed,
                        int16_t*         h_ci16,
                        cudaStream_t     stream)
{
  buf &= 1u;
  cudaMemcpyAsync(
      pipe->d_compressed[buf], h_compressed, pipe->compressed_bytes, cudaMemcpyHostToDevice, stream);

  lowphy_bfp_decompress(pipe->d_compressed[buf],
                        pipe->d_grid_cbf16[buf],
                        pipe->nof_ports,
                        pipe->nof_symbols_per_slot,
                        pipe->nof_prbs,
                        pipe->data_width,
                        stream);

  lowphy_ofdm_mod_params mod{};
  mod.plan                 = pipe->mod_plan;
  mod.grid                 = pipe->d_grid_cbf16[buf];
  mod.out                  = pipe->d_ci16[buf];
  mod.port_empty           = pipe->d_port_empty;
  mod.phase                = pipe->d_phase_mod;
  mod.cp_len               = pipe->d_cp_len;
  mod.symbol_start         = pipe->d_symbol_start;
  mod.nof_ports            = pipe->nof_ports;
  mod.nof_symbols_per_slot = pipe->nof_symbols_per_slot;
  mod.dft_size             = pipe->dft_size;
  mod.bw_rb                = pipe->bw_rb;
  mod.slot_index           = slot_index;
  mod.slot_start           = slot_start;
  mod.slot_samples         = pipe->slot_samples;
  mod.scale                = 1.0f;

  lowphy_ofdm_mod_pre(mod, stream);
  lowphy_ofdm_mod_fft(mod, stream);
  lowphy_ofdm_mod_post(mod, stream);

  cudaMemcpyAsync(h_ci16, pipe->d_ci16[buf], pipe->ci16_bytes, cudaMemcpyDeviceToHost, stream);
}

void lowphy_pipeline_ul(lowphy_pipeline* pipe,
                        unsigned         buf,
                        unsigned         slot_index,
                        unsigned         slot_start,
                        const int16_t*   h_ci16,
                        uint8_t*         h_compressed,
                        cudaStream_t     stream)
{
  buf &= 1u;
  cudaMemcpyAsync(pipe->d_ci16[buf], h_ci16, pipe->ci16_bytes, cudaMemcpyHostToDevice, stream);

  const float demod_scale =
      1.0f / sqrtf(static_cast<float>(pipe->bw_rb * 12u));

  lowphy_ofdm_demod_params demod{};
  demod.plan                 = pipe->demod_plan;
  demod.in                   = pipe->d_ci16[buf];
  demod.grid                 = pipe->d_grid_cf32[buf];
  demod.phase                = pipe->d_phase_demod;
  demod.window_phase         = nullptr;
  demod.cp_len               = pipe->d_cp_len;
  demod.symbol_start         = pipe->d_symbol_start;
  demod.nof_ports            = pipe->nof_ports;
  demod.nof_symbols_per_slot = pipe->nof_symbols_per_slot;
  demod.dft_size             = pipe->dft_size;
  demod.bw_rb                = pipe->bw_rb;
  demod.slot_index           = slot_index;
  demod.slot_start           = slot_start;
  demod.slot_samples         = pipe->slot_samples;
  demod.window_offset        = 0;
  demod.scale                = demod_scale;

  lowphy_ofdm_demod_pre(demod, stream);
  lowphy_ofdm_demod_fft(demod, stream);
  lowphy_ofdm_demod_post(demod, stream);

  const unsigned n_complex =
      pipe->nof_ports * pipe->nof_symbols_per_slot * pipe->bw_rb * 12u;
  lowphy_cf32_to_cbf16(pipe->d_grid_cf32[buf], pipe->d_grid_cbf16[buf], n_complex, stream);

  lowphy_bfp_compress(pipe->d_grid_cbf16[buf],
                      pipe->d_compressed[buf],
                      pipe->nof_ports,
                      pipe->nof_symbols_per_slot,
                      pipe->nof_prbs,
                      pipe->data_width,
                      stream);

  cudaMemcpyAsync(
      h_compressed, pipe->d_compressed[buf], pipe->compressed_bytes, cudaMemcpyDeviceToHost, stream);
}
