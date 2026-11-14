// SPDX-FileCopyrightText: Copyright (C) 2026 Software Radio Systems Limited
// SPDX-License-Identifier: BSD-3-Clause-Open-MPI

#pragma once

#include "lowphy_cuda.h"

/// \brief Test-only radix-2 OFDM reference parameters.
///
/// This API is not part of the production path. It is retained only so the standalone test
/// can cross-check the cuFFT implementation on power-of-two DFT sizes.
struct lowphy_radix2_mod_params {
  const uint16_t*    grid;
  int16_t*           out;
  unsigned           nof_ports;
  unsigned           nof_symbols_per_slot;
  unsigned           dft_size;
  unsigned           bw_rb;
  unsigned           slot_index;
  unsigned           nof_symbols_per_sf;
  const unsigned*    cp_len;
  const unsigned*    symbol_start;
  unsigned           slot_start;
  unsigned           slot_samples;
  const lowphy_cf32* phase;
  float              scale;
  const uint8_t*     port_empty;
  const lowphy_cf32* twiddles;
  unsigned           logn;
};

void lowphy_radix2_modulate(const lowphy_radix2_mod_params& params, cudaStream_t stream);

/// \brief Test-only radix-2 OFDM reference parameters.
struct lowphy_radix2_demod_params {
  const int16_t*     in;
  lowphy_cf32*       grid;
  unsigned           nof_ports;
  unsigned           nof_symbols_per_slot;
  unsigned           dft_size;
  unsigned           bw_rb;
  unsigned           slot_index;
  unsigned           nof_symbols_per_sf;
  const unsigned*    cp_len;
  const unsigned*    symbol_start;
  unsigned           slot_start;
  unsigned           slot_samples;
  unsigned           window_offset;
  const lowphy_cf32* phase;
  const lowphy_cf32* window_phase;
  float              scale;
  const lowphy_cf32* twiddles;
  unsigned           logn;
};

void lowphy_radix2_demodulate(const lowphy_radix2_demod_params& params, cudaStream_t stream);
