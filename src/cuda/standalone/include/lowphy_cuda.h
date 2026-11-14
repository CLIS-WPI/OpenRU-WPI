// SPDX-FileCopyrightText: Copyright (C) 2026 Software Radio Systems Limited
// SPDX-License-Identifier: BSD-3-Clause-Open-MPI

#pragma once

#include <cstdint>
#include <cuda_runtime.h>

/// Complex single-precision value with a layout compatible with ocudu::cf_t.
struct lowphy_cf32 {
  float re;
  float im;
};

/// \brief BFP compression.
///
/// \param[in]  grid       Resource grid in cbf16 format, layout [port][symbol][prb * 12].
/// \param[out] out        Compressed PRBs, layout [port][symbol][prb].
/// \param[in]  nof_ports  Number of ports.
/// \param[in]  nof_symbols Number of symbols per slot.
/// \param[in]  nof_prbs   Number of PRBs per symbol.
/// \param[in]  data_width BFP bit width (8..16).
/// \param[in]  stream     CUDA stream.
void lowphy_bfp_compress(const uint16_t* grid,
                         uint8_t*        out,
                         unsigned        nof_ports,
                         unsigned        nof_symbols,
                         unsigned        nof_prbs,
                         unsigned        data_width,
                         cudaStream_t    stream);

/// \brief BFP decompression.
///
/// \param[in]  in          Compressed PRBs, layout [port][symbol][prb].
/// \param[out] grid        Resource grid in cbf16 format, layout [port][symbol][prb * 12].
/// \param[in]  nof_ports   Number of ports.
/// \param[in]  nof_symbols Number of symbols per slot.
/// \param[in]  nof_prbs    Number of PRBs per symbol.
/// \param[in]  data_width  BFP bit width (8..16).
/// \param[in]  stream      CUDA stream.
void lowphy_bfp_decompress(const uint8_t* in,
                           uint16_t*      grid,
                           unsigned       nof_ports,
                           unsigned       nof_symbols,
                           unsigned       nof_prbs,
                           unsigned       data_width,
                           cudaStream_t   stream);

/// \brief OFDM transform plan.
///
/// Owns one batched cuFFT plan covering all ports and all symbols of a slot, plus the
/// device-side complex scratch buffers used by the pre and post kernels. A plan is
/// created per (dft_size, nof_ports) pair and per transform direction.
struct lowphy_ofdm_plan;

/// \brief Creates a batched cuFFT plan.
/// \param[in] dft_size             DFT size.
/// \param[in] nof_ports            Number of ports.
/// \param[in] nof_symbols_per_slot Number of symbols per slot.
/// \param[in] inverse              True for modulation (inverse DFT), false for demodulation (direct DFT).
/// \return A plan on success, nullptr if cuFFT or the device allocation fails.
lowphy_ofdm_plan* lowphy_ofdm_plan_create(unsigned dft_size,
                                          unsigned nof_ports,
                                          unsigned nof_symbols_per_slot,
                                          bool     inverse);

/// \brief Destroys an OFDM plan and releases its device resources.
void lowphy_ofdm_plan_destroy(lowphy_ofdm_plan* plan);

/// \brief OFDM modulation parameters.
struct lowphy_ofdm_mod_params {
  /// Transform plan created for (dft_size, nof_ports) with inverse=true.
  lowphy_ofdm_plan* plan;
  /// Input resource grid in cbf16 format, layout [port][symbol][bw_rb * 12].
  const uint16_t* grid;
  /// Output time-domain samples in ci16 format, layout [port][slot_samples].
  int16_t* out;
  /// Port emptiness flags, one per port (1 means empty), or nullptr.
  const uint8_t* port_empty;
  /// Phase compensation coefficient per subframe symbol.
  const lowphy_cf32* phase;
  /// Cyclic prefix length per subframe symbol.
  const unsigned* cp_len;
  /// Absolute sample offset of each subframe symbol.
  const unsigned* symbol_start;
  /// Number of ports.
  unsigned nof_ports;
  /// Number of symbols per slot (14 for normal CP).
  unsigned nof_symbols_per_slot;
  /// DFT size.
  unsigned dft_size;
  /// Bandwidth in resource blocks.
  unsigned bw_rb;
  /// Slot index within the subframe.
  unsigned slot_index;
  /// Absolute sample offset of the first symbol in the slot.
  unsigned slot_start;
  /// Number of samples in the slot.
  unsigned slot_samples;
  /// Scaling factor applied at the DFT output.
  float scale;
};

/// \brief Modulation stage 1: maps the resource grid into the cuFFT input buffer.
void lowphy_ofdm_mod_pre(const lowphy_ofdm_mod_params& params, cudaStream_t stream);

/// \brief Modulation stage 2: executes the inverse DFT over all ports and symbols.
void lowphy_ofdm_mod_fft(const lowphy_ofdm_mod_params& params, cudaStream_t stream);

/// \brief Modulation stage 3: phase compensation, scaling, ci16 conversion and CP insertion.
void lowphy_ofdm_mod_post(const lowphy_ofdm_mod_params& params, cudaStream_t stream);

/// \brief OFDM demodulation parameters.
struct lowphy_ofdm_demod_params {
  /// Transform plan created for (dft_size, nof_ports) with inverse=false.
  lowphy_ofdm_plan* plan;
  /// Input time-domain samples in ci16 format, layout [port][slot_samples].
  const int16_t* in;
  /// Output resource grid in cf32 format, layout [port][symbol][bw_rb * 12].
  lowphy_cf32* grid;
  /// Phase compensation coefficient per subframe symbol.
  const lowphy_cf32* phase;
  /// Window offset phase compensation per DFT bin, or nullptr.
  const lowphy_cf32* window_phase;
  /// Cyclic prefix length per subframe symbol.
  const unsigned* cp_len;
  /// Absolute sample offset of each subframe symbol.
  const unsigned* symbol_start;
  /// Number of ports.
  unsigned nof_ports;
  /// Number of symbols per slot (14 for normal CP).
  unsigned nof_symbols_per_slot;
  /// DFT size.
  unsigned dft_size;
  /// Bandwidth in resource blocks.
  unsigned bw_rb;
  /// Slot index within the subframe.
  unsigned slot_index;
  /// Absolute sample offset of the first symbol in the slot.
  unsigned slot_start;
  /// Number of samples in the slot.
  unsigned slot_samples;
  /// DFT window offset in samples.
  unsigned window_offset;
  /// Scaling factor applied at the DFT output.
  float scale;
};

/// \brief Demodulation stage 1: copies the time-domain samples into the cuFFT input buffer.
void lowphy_ofdm_demod_pre(const lowphy_ofdm_demod_params& params, cudaStream_t stream);

/// \brief Demodulation stage 2: executes the direct DFT over all ports and symbols.
void lowphy_ofdm_demod_fft(const lowphy_ofdm_demod_params& params, cudaStream_t stream);

/// \brief Demodulation stage 3: phase compensation, scaling and resource grid mapping.
void lowphy_ofdm_demod_post(const lowphy_ofdm_demod_params& params, cudaStream_t stream);
