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

/// \brief OFDM modulation parameters.
struct lowphy_ofdm_mod_params {
  /// Input resource grid in cbf16 format, layout [port][symbol][bw_rb * 12].
  const uint16_t* grid;
  /// Output time-domain samples in ci16 format, layout [port][slot_samples].
  int16_t* out;
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
  /// Number of symbols per subframe.
  unsigned nof_symbols_per_sf;
  /// Cyclic prefix length per subframe symbol.
  const unsigned* cp_len;
  /// Absolute sample offset of each subframe symbol.
  const unsigned* symbol_start;
  /// Absolute sample offset of the first symbol in the slot.
  unsigned slot_start;
  /// Number of samples in the slot.
  unsigned slot_samples;
  /// Phase compensation coefficient per subframe symbol.
  const lowphy_cf32* phase;
  /// Scaling factor applied at the DFT output.
  float scale;
  /// Port emptiness flags, one per port (1 means empty).
  const uint8_t* port_empty;
  /// Twiddle factors exp(j * sign * 2 * pi * k / dft_size) for k in [0, dft_size / 2).
  const lowphy_cf32* twiddles;
  /// log2(dft_size).
  unsigned logn;
};

void lowphy_ofdm_modulate(const lowphy_ofdm_mod_params& params, cudaStream_t stream);

/// \brief OFDM demodulation parameters.
struct lowphy_ofdm_demod_params {
  /// Input time-domain samples in ci16 format, layout [port][slot_samples].
  const int16_t* in;
  /// Output resource grid in cf32 format, layout [port][symbol][bw_rb * 12].
  lowphy_cf32* grid;
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
  /// Number of symbols per subframe.
  unsigned nof_symbols_per_sf;
  /// Cyclic prefix length per subframe symbol.
  const unsigned* cp_len;
  /// Absolute sample offset of each subframe symbol.
  const unsigned* symbol_start;
  /// Absolute sample offset of the first symbol in the slot.
  unsigned slot_start;
  /// Number of samples in the slot.
  unsigned slot_samples;
  /// DFT window offset in samples.
  unsigned window_offset;
  /// Phase compensation coefficient per subframe symbol.
  const lowphy_cf32* phase;
  /// Window offset phase compensation per DFT bin, or nullptr.
  const lowphy_cf32* window_phase;
  /// Scaling factor applied at the DFT output.
  float scale;
  /// Twiddle factors exp(j * sign * 2 * pi * k / dft_size) for k in [0, dft_size / 2).
  const lowphy_cf32* twiddles;
  /// log2(dft_size).
  unsigned logn;
};

void lowphy_ofdm_demodulate(const lowphy_ofdm_demod_params& params, cudaStream_t stream);
