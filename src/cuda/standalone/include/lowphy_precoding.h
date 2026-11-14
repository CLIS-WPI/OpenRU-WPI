// SPDX-FileCopyrightText: Copyright (C) 2026 Software Radio Systems Limited
// SPDX-License-Identifier: BSD-3-Clause-Open-MPI
#pragma once

#include "lowphy_cuda.h"

#include <cstdint>

/// Category-B DL precoding: layers → ports, one complex matrix per PRB.
/// Layout: grid_in  [layer][symbol][subcarrier] as cbf16 (uint16 pairs)
///         weights  [prb][port][layer] as lowphy_cf32
///         grid_out [port][symbol][subcarrier] as cbf16
void lowphy_catb_precode(const uint16_t*    grid_in,
                         const lowphy_cf32* weights,
                         uint16_t*          grid_out,
                         unsigned           nof_layers,
                         unsigned           nof_ports,
                         unsigned           nof_symbols,
                         unsigned           nof_prbs,
                         cudaStream_t       stream);

/// Category-B UL combining: ports → layers (W^H), one matrix per PRB.
/// Layout: grid_in  [port][symbol][subcarrier] as cf32
///         weights  [prb][port][layer] as lowphy_cf32 (same DL weights; conjugate-transpose applied)
///         grid_out [layer][symbol][subcarrier] as cbf16
void lowphy_catb_combine(const lowphy_cf32* grid_in,
                         const lowphy_cf32* weights,
                         uint16_t*          grid_out,
                         unsigned           nof_layers,
                         unsigned           nof_ports,
                         unsigned           nof_symbols,
                         unsigned           nof_prbs,
                         cudaStream_t       stream);
