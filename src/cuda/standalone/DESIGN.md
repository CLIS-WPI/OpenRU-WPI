# Standalone CUDA Low-PHY Kernels

This directory contains standalone CUDA implementations of the two Low-PHY blocks that
dominate the fronthaul/PHY boundary in the OCUDU lower PHY:

- BFP IQ compression and decompression for the O-RAN eCPRI data path.
- OFDM modulation and demodulation for the 30 kHz / 20, 40 and 100 MHz profiles.

The kernels are deliberately kept outside the OCUDU build graph. They share no globals,
no logging and no allocator with the reference implementation, so they can be validated
against it and later moved into the lower-PHY processor without behavioural surprises.

The validation harness links the production OCUDU static libraries and compares every
output against the CPU reference (`iq_compression_bfp_impl`, `iq_compression_bfp_avx2`,
`ofdm_modulator_impl`, `ofdm_demodulator_impl`).

## Files

| File | Contents |
|---|---|
| `include/lowphy_cuda.h` | Public C++ interface, parameter structs and launch declarations. |
| `kernels/bfp_kernels.cu` | BFP compress/decompress kernels. |
| `kernels/ofdm_kernels.cu` | OFDM modulate/demodulate kernels. |
| `tests/test_lowphy.cpp` | Correctness and timing harness. |
| `CMakeLists.txt` | Standalone build against a prepared OCUDU build tree. |

## BFP compression

### Reference semantics

The CPU implementation (`lib/ofh/compression/iq_compression_bfp_impl.cpp`) works on one
PRB at a time. A PRB is 12 complex samples, i.e. 24 `int16` values stored as `cbf16_t`.
The algorithm is:

1. Find the maximum magnitude in the PRB using the signed 16-bit range
   (`max(abs(max), abs(min) - 1)`); a PRB of zeros produces exponent 0.
2. Derive the exponent from the leading-zero count,
   `exponent = max(0, (16 - width) - min(16 - width, clz(x) - 17))`.
3. Quantize each sample with round-to-nearest-even on the scaled integer and keep the
   low `width` bits.
4. Store the 4-bit exponent followed by the packed samples, MSB first, big endian.

The packing layout is `1 + ceil(24 * width / 8)` bytes per PRB.

### Kernel design

- One warp per PRB, eight warps per block.
- The warp computes the maximum magnitude in shared memory, derives the exponent once,
  quantizes its 24 samples into shared memory and then cooperatively packs the bitstream.
- Packing uses big-endian bit offsets computed per lane and `atomicOr` into a zeroed
  word buffer, which keeps the PRB write order independent of lane scheduling.
- Decompression computes each sample's bit offset, reads at most two 32-bit words, and
  reconstructs `float = int16 * 2^exponent / 32767`, then rounds to `bf16` with the same
  integer trick as `ocudu::to_bf16`.

`__float2int_rn` is used for quantization so the GPU rounds identically to the SSE/AVX
round-to-nearest-even conversion used by the CPU SIMD path. The compressed stream is a
byte-for-byte match with both the generic and the AVX2 CPU implementations for every
width and every profile tested.

## OFDM modulation and demodulation

### Reference semantics

- Grid layout is `[port][symbol][subcarrier]`, with `cbf16_t` elements in the resource
  grid. Subcarriers are DC-centred: subcarrier 0 maps to DFT bin `N - bw/2`, subcarrier
  `bw/2` maps to DC and subcarrier `bw - 1` maps to bin `bw/2 - 1`.
- The modulator uses an unnormalised inverse DFT (twiddle sign `+1`), multiplies the
  result by `phase(symbol) * scale`, and copies the cyclic prefix from the tail of the
  body.
- The demodulator uses an unnormalised direct DFT (twiddle sign `-1`), multiplies by
  `phase(symbol) * scale`, and writes the DC-centred bins back to the grid.
- `phase(symbol)` is the TS 38.211 Section 5.4 compensation coefficient. For the
  modulator it is built with `is_tx = true`, for the demodulator with `is_tx = false`.

### Kernel design

- One thread block per `(port, symbol)`.
- The DFT input is written directly in bit-reversed order into shared memory, so the
  iterative radix-2 decimation-in-time stages can run without a separate permutation.
- Complex multiplies use `__fmaf_rn`/`__fmul_rn` with the same operand order as
  `ocudu_simd_cf_prod`, so the twiddle and phase products round like the CPU AVX-512 path.
- The twiddle table is generated on the host with
  `std::polar(1.0f, sign * 2 * pi * k / N)` for `k` in `[0, N/2)`.
- Guard subcarriers are explicitly zeroed. The cyclic prefix is copied from
  `body[N - cp_len + n]`.
- Modulation writes `ci16_t` with saturation. Demodulation writes `cf32` so the harness
  can measure the numerical error before the production `cbf16` quantization step.

### Numerical result

- BFP: zero differing bytes and zero differing `bf16` values against both CPU
  implementations, for widths 8, 9, 10, 12 and 16.
- Modulation: identical `ci16` output except for a small number of samples that differ by
  exactly 1 LSB (at most 28 of 30,720 samples for 20 MHz / 2 ports and 644 of 245,760
  samples for 100 MHz / 4 ports, per slot). The difference comes from the CPU radix-2
  base cases using direct DFT evaluation while the GPU uses radix-2 butterflies; both are
  mathematically identical and the observed deviation is one quantization step.
- Demodulation: maximum relative error `4.4e-7`, maximum absolute error `3.4e-7`,
  sampled on the unquantized `cf32` grid.

## Timing methodology

The harness allocates pinned host buffers, warms each kernel three times, then runs 30
iterations per configuration on an NVIDIA H100 NVL (compute capability 9.0). CUDA events
time the host-to-device copy, the kernel and the device-to-host copy separately. The
reported kernel times are compute-only and exclude copies. The harness pins the GPU with
`CUDA_VISIBLE_DEVICES`; it never touches the other device on the host.

## Limitations

- The demodulator is intentionally `cf32`; production integration must add the same
  `bf16` quantization used by the resource-grid writer.
- The modulator uses a per-symbol block launch. A production integration would batch
  all symbols of a slot, or all slots of a subframe, into a single launch.
- The FFT is a straightforward radix-2 kernel. It is not the fastest possible GPU FFT;
  it is chosen because its floating-point operation order is the closest match to the
  CPU reference and it keeps the bit-exactness argument simple.
