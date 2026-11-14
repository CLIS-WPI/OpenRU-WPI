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
| `kernels/ofdm_cufft.cu` | cuFFT-backed OFDM plan and pre/FFT/post stages. |
| `tests/ofdm_radix2_reference.cu` | Test-only radix-2 FFT reference (power-of-two sizes). |
| `tests/ofdm_radix2_reference.h` | Test-only radix-2 reference interface. |
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
- The decompressor bounds-checks the packed byte range so an unaligned PRB at the end of
  the buffer cannot read past it.

`__float2int_rn` is used for quantization so the GPU rounds identically to the SSE/AVX
round-to-nearest-even conversion used by the CPU SIMD path. The compressed stream is a
byte-for-byte match with both the generic and the AVX2 CPU implementations for every
width and every profile tested.

## OFDM modulation and demodulation

### Reference semantics

- Grid layout is `[port][symbol][subcarrier]`, with `cbf16_t` elements in the resource
  grid. Subcarriers are DC-centred: subcarrier 0 maps to DFT bin `N - bw/2`, subcarrier
  `bw/2` maps to DC and subcarrier `bw - 1` maps to bin `bw/2 - 1`.
- The modulator uses an unnormalised inverse DFT, multiplies the result by
  `phase(symbol) * scale`, and copies the cyclic prefix from the tail of the body.
- The demodulator uses an unnormalised direct DFT, multiplies by `phase(symbol) * scale`,
  and writes the DC-centred bins back to the grid.
- `phase(symbol)` is the TS 38.211 Section 5.4 compensation coefficient. For the
  modulator it is built with `is_tx = true`, for the demodulator with `is_tx = false`.
- The DFT size is derived from the sampling rate exactly as the lower PHY does:
  `ocudu::sampling_rate::from_Hz(srate).get_dft_size(scs)`. The three test profiles are
  23.04 MHz / 51 PRB / DFT 768, 46.08 MHz / 106 PRB / DFT 1536 and
  122.88 MHz / 273 PRB / DFT 4096.

### Kernel design

- `lowphy_ofdm_plan` owns one `cufftPlanMany` per `(dft_size, nof_ports)` and one per
  direction, plus the complex input/output scratch buffers.
- The plan batches all ports and all 14 symbols of a slot into a single C2C transform
  (`batch = nof_ports * 14`, contiguous `istride = ostride = 1`, `idist = odist = N`).
- Modulation and demodulation are each split into three stages on the same stream:
  1. A pre kernel maps the resource grid into the cuFFT input (modulation) or copies the
     CP-stripped time samples into the cuFFT input (demodulation).
  2. `cufftExecC2C` runs the unnormalised inverse or direct transform for the whole slot.
  3. A post kernel applies phase compensation and scaling, converts to `ci16` and
     inserts the CP (modulation), or maps the bins back into the `cf32` grid
     (demodulation).
- Complex multiplies use `__fmaf_rn`/`__fmul_rn` with the same operand order as
  `ocudu_simd_cf_prod`.
- Guard subcarriers are explicitly zeroed in both directions. The cyclic prefix is
  inserted from `body[N - cp_len + n]`.
- One pre launch, one cuFFT execution and one post launch cover the whole slot; the
  harness times them separately.
- `tests/ofdm_radix2_reference.cu` keeps the original radix-2 DIT kernel as a
  test-only cross-check. It is compiled into the test executable, not into the library,
  and only runs for power-of-two DFT sizes (4096 in this configuration). It is not part
  of the production path.

### Acceptance criteria

Per profile and port count, over the two slots of the subframe:

- Modulation: `max |gpu - cpu| <= 1` ci16 LSB, and
  `10 log10(sum |gpu-cpu|^2 / sum |cpu|^2) <= -60 dB`.
- Demodulation: the same measurements on the unquantised `cf32` grid, with the error
  expressed in ci16 LSB (`|gpu - cpu| * 32767`). A sample counts as differing when its
  error is at least 0.5 LSB.

### Numerical result

- BFP: zero differing bytes and zero differing `bf16` values against both CPU
  implementations, for widths 8, 9, 10, 12 and 16.
- Modulation: at most 1 LSB difference on a small fraction of samples; error power
  between `-102` and `-105` dB relative to the signal for every profile and port count.
- Demodulation: maximum error between `0.0066` and `0.0209` LSB; zero samples differ by
  0.5 LSB or more; error power between `-129` and `-130` dB.
- The radix-2 test-only reference also matches the CPU within 1 LSB on the 4096 profile,
  which confirms the cuFFT result is not an artefact of a shared mapping bug.

## Timing methodology

The harness allocates pinned host buffers, warms each configuration three times, then
runs 30 iterations per configuration on an NVIDIA H100 NVL (compute capability 9.0).
CUDA events time host-to-device, pre kernel, cuFFT, post kernel and device-to-host
separately. The reported OFDM compute time is `pre + cuFFT + post` and excludes copies.
The harness pins the GPU with `CUDA_VISIBLE_DEVICES`; it never touches the other device
on the host. Before each build and GPU run the harness operator confirms that
`/tmp/openru-measure.lock` is absent.

## Limitations

- The demodulator is intentionally `cf32`; production integration must add the same
  `bf16` quantization used by the resource-grid writer.
- The plan is created per `(dft_size, nof_ports)` and per direction; a production
  integration should cache it in the lower-PHY processor and reuse it across slots.
- cuFFT is a closed-source library. The numerical comparison above is the evidence that
  its single-precision transform matches the OCUDU generic DFT within the acceptance
  bounds; the radix-2 reference remains available for independent spot checks.
