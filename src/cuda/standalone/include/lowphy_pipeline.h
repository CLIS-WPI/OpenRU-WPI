// SPDX-FileCopyrightText: Copyright (C) 2026 Software Radio Systems Limited
// SPDX-License-Identifier: BSD-3-Clause-Open-MPI
#pragma once

#include "lowphy_cuda.h"

#include <cstddef>
#include <cstdint>

/// Device-resident DL/UL low-PHY pipeline: one H2D, on-device chain, one D2H.
struct lowphy_pipeline {
  unsigned nof_ports            = 0;
  unsigned nof_symbols_per_slot = 14;
  unsigned nof_prbs             = 0;
  unsigned data_width           = 9;
  unsigned dft_size             = 0;
  unsigned bw_rb                = 0;
  unsigned slot_samples         = 0;
  unsigned prb_packed_bytes     = 0;

  lowphy_ofdm_plan* mod_plan   = nullptr;
  lowphy_ofdm_plan* demod_plan = nullptr;

  lowphy_cf32* d_phase_mod    = nullptr;
  lowphy_cf32* d_phase_demod  = nullptr;
  unsigned*    d_cp_len       = nullptr;
  unsigned*    d_symbol_start = nullptr;
  uint8_t*     d_port_empty   = nullptr;

  // Double-buffered working sets.
  uint8_t*     d_compressed[2] = {nullptr, nullptr};
  uint16_t*    d_grid_cbf16[2] = {nullptr, nullptr};
  lowphy_cf32* d_grid_cf32[2]  = {nullptr, nullptr};
  int16_t*     d_ci16[2]       = {nullptr, nullptr};

  size_t compressed_bytes = 0;
  size_t cbf16_bytes      = 0;
  size_t cf32_bytes       = 0;
  size_t ci16_bytes       = 0;
};

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
                            const unsigned*    symbol_start_host);

void lowphy_pipeline_destroy(lowphy_pipeline* pipe);

void lowphy_pipeline_dl(lowphy_pipeline* pipe,
                        unsigned         buf,
                        unsigned         slot_index,
                        unsigned         slot_start,
                        const uint8_t*   h_compressed,
                        int16_t*         h_ci16,
                        cudaStream_t     stream);

void lowphy_pipeline_ul(lowphy_pipeline* pipe,
                        unsigned         buf,
                        unsigned         slot_index,
                        unsigned         slot_start,
                        const int16_t*   h_ci16,
                        uint8_t*         h_compressed,
                        cudaStream_t     stream);

/// Convert a device cf32 grid to cbf16 (bf16 bit pattern per float component).
void lowphy_cf32_to_cbf16(const lowphy_cf32* in, uint16_t* out, unsigned n_complex, cudaStream_t stream);
