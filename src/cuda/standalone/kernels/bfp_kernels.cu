// SPDX-FileCopyrightText: Copyright (C) 2026 Software Radio Systems Limited
// SPDX-License-Identifier: BSD-3-Clause-Open-MPI

#include "lowphy_cuda.h"

namespace {

constexpr unsigned WARPS_PER_BLOCK  = 8;
constexpr unsigned THREADS_PER_BLOCK = 32 * WARPS_PER_BLOCK;
constexpr unsigned COMPLEX_PER_PRB  = 12;
constexpr unsigned SAMPLES_PER_PRB  = 2 * COMPLEX_PER_PRB;
constexpr unsigned MAX_PACKED_BYTES = (SAMPLES_PER_PRB * 16) / 8;
constexpr unsigned MAX_PACKED_WORDS = (MAX_PACKED_BYTES + 3) / 4;

__device__ __forceinline__ float bf16_to_float(uint16_t value)
{
  return __uint_as_float(static_cast<uint32_t>(value) << 16);
}

__device__ __forceinline__ uint16_t float_to_bf16(float value)
{
  uint32_t bits = __float_as_uint(value);
  bits += 0x7fffu + ((bits >> 16) & 1u);
  return static_cast<uint16_t>(bits >> 16);
}

__device__ __forceinline__ int determine_exponent(unsigned x, unsigned data_width)
{
  unsigned max_shift       = 16 - data_width;
  unsigned lz_without_sign = max_shift;

  if ((x > 0) && (max_shift > 0)) {
    lz_without_sign = __clz(x) - 16u - 1u;
  }

  int raw_exp = min(static_cast<int>(max_shift), static_cast<int>(lz_without_sign));
  return max(0, static_cast<int>(16 - data_width) - raw_exp);
}

__global__ void bfp_compress_kernel(const uint16_t* __restrict__ grid,
                                    uint8_t* __restrict__       out,
                                    unsigned                    nof_symbols,
                                    unsigned                    nof_prbs,
                                    unsigned                    data_width)
{
  const unsigned warp = threadIdx.x >> 5;
  const unsigned lane = threadIdx.x & 31u;
  const unsigned prb  = blockIdx.x * WARPS_PER_BLOCK + warp;

  if (prb >= nof_prbs) {
    return;
  }

  const unsigned port = blockIdx.z;
  const unsigned sym  = blockIdx.y;

  const unsigned grid_base = ((port * nof_symbols + sym) * nof_prbs + prb) * SAMPLES_PER_PRB;

  __shared__ int16_t  samples[WARPS_PER_BLOCK][SAMPLES_PER_PRB];
  __shared__ uint32_t packed[WARPS_PER_BLOCK][MAX_PACKED_WORDS];
  __shared__ int      exponent[WARPS_PER_BLOCK];

  if (lane < MAX_PACKED_WORDS) {
    packed[warp][lane] = 0;
  }
  __syncwarp();

  int quantized = 0;
  if (lane < SAMPLES_PER_PRB) {
    float value = bf16_to_float(grid[grid_base + lane]);
    if (fabsf(value) > 1.0f) {
      value = copysignf(1.0f, value);
    }
    quantized            = __float2int_rn(value * 32767.0f);
    samples[warp][lane]  = static_cast<int16_t>(quantized);
  }
  __syncwarp();

  if (lane == 0) {
    int max_value = -32768;
    int min_value = 32767;
    for (unsigned i = 0; i != SAMPLES_PER_PRB; ++i) {
      int value = samples[warp][i];
      max_value = max(max_value, value);
      min_value = min(min_value, value);
    }
    int      max_abs_int = max(abs(max_value), abs(min_value) - 1);
    unsigned max_abs     = static_cast<unsigned>(max_abs_int);
    exponent[warp]       = determine_exponent(max_abs, data_width);
  }
  __syncwarp();

  const int      exp      = exponent[warp];
  const unsigned width    = data_width;
  const unsigned prb_size = 1 + ((SAMPLES_PER_PRB * width + 7) >> 3);
  const unsigned prb_off  = ((port * nof_symbols + sym) * nof_prbs + prb) * prb_size;

  if (lane == 0) {
    out[prb_off] = static_cast<uint8_t>(exp);
  }

  if (lane < SAMPLES_PER_PRB) {
    const uint32_t mask = (1u << width) - 1u;
    const uint32_t value =
        static_cast<uint32_t>(static_cast<int>(samples[warp][lane]) >> exp) & mask;
    const unsigned bitpos = lane * width;
    const unsigned first  = bitpos >> 3;
    const unsigned last   = (bitpos + width - 1) >> 3;

    for (unsigned byte = first; byte <= last; ++byte) {
      int start = max(static_cast<int>(bitpos), static_cast<int>(byte * 8));
      int end   = min(static_cast<int>(bitpos + width), static_cast<int>(byte * 8 + 8));
      int count = end - start;
      int k0    = start - static_cast<int>(bitpos);

      uint32_t chunk = (value >> (width - k0 - count)) & ((1u << count) - 1u);
      int      shift = 7 - (static_cast<int>(bitpos) + k0 + count - 1 - static_cast<int>(byte * 8));

      atomicOr(&packed[warp][byte >> 2], chunk << (shift + 8 * (byte & 3)));
    }
  }
  __syncwarp();

  for (unsigned byte = lane; byte < prb_size - 1; byte += 32) {
    out[prb_off + 1 + byte] = reinterpret_cast<const uint8_t*>(packed[warp])[byte];
  }
}

__global__ void bfp_decompress_kernel(const uint8_t* __restrict__ in,
                                      uint16_t* __restrict__       grid,
                                      unsigned                     nof_symbols,
                                      unsigned                     nof_prbs,
                                      unsigned                     data_width)
{
  const unsigned warp = threadIdx.x >> 5;
  const unsigned lane = threadIdx.x & 31u;
  const unsigned prb  = blockIdx.x * WARPS_PER_BLOCK + warp;

  if (prb >= nof_prbs) {
    return;
  }

  const unsigned port = blockIdx.z;
  const unsigned sym  = blockIdx.y;

  const unsigned width    = data_width;
  const unsigned prb_size = 1 + ((SAMPLES_PER_PRB * width + 7) >> 3);
  const unsigned prb_off  = ((port * nof_symbols + sym) * nof_prbs + prb) * prb_size;
  const uint8_t* packed   = in + prb_off + 1;
  const unsigned exp      = in[prb_off];

  if (lane >= SAMPLES_PER_PRB) {
    return;
  }

  const unsigned bitpos = lane * width;
  const unsigned byte   = bitpos >> 3;
  const unsigned shift  = bitpos & 7;

  // Assemble a 24-bit big-endian window. Bytes past the packed PRB are treated as zero so
  // the kernel never reads outside the compressed buffer of the last PRB.
  const unsigned packed_bytes = prb_size - 1;
  auto           load_byte    = [&](unsigned idx) -> uint32_t {
    return (idx < packed_bytes) ? packed[idx] : 0u;
  };
  uint32_t word = (load_byte(byte) << 16) | (load_byte(byte + 1) << 8) | load_byte(byte + 2);

  const uint32_t mask = (1u << width) - 1u;
  const uint32_t uval = (word >> (24 - shift - width)) & mask;
  const int      sval = static_cast<int32_t>(uval << (32 - width)) >> (32 - width);

  const int   scaled = sval * (1 << exp);
  const float value  = static_cast<float>(scaled) / 32767.0f;

  const unsigned grid_base = ((port * nof_symbols + sym) * nof_prbs + prb) * SAMPLES_PER_PRB;
  grid[grid_base + lane]   = float_to_bf16(value);
}

} // namespace

void lowphy_bfp_compress(const uint16_t* grid,
                         uint8_t*        out,
                         unsigned        nof_ports,
                         unsigned        nof_symbols,
                         unsigned        nof_prbs,
                         unsigned        data_width,
                         cudaStream_t    stream)
{
  dim3 grid_dim((nof_prbs + WARPS_PER_BLOCK - 1) / WARPS_PER_BLOCK, nof_symbols, nof_ports);
  bfp_compress_kernel<<<grid_dim, THREADS_PER_BLOCK, 0, stream>>>(
      grid, out, nof_symbols, nof_prbs, data_width);
}

void lowphy_bfp_decompress(const uint8_t* in,
                           uint16_t*      grid,
                           unsigned       nof_ports,
                           unsigned       nof_symbols,
                           unsigned       nof_prbs,
                           unsigned       data_width,
                           cudaStream_t   stream)
{
  dim3 grid_dim((nof_prbs + WARPS_PER_BLOCK - 1) / WARPS_PER_BLOCK, nof_symbols, nof_ports);
  bfp_decompress_kernel<<<grid_dim, THREADS_PER_BLOCK, 0, stream>>>(
      in, grid, nof_symbols, nof_prbs, data_width);
}
