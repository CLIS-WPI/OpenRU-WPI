// SPDX-FileCopyrightText: Copyright (C) 2026 CLIS-WPI / OpenRU
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Unit test for the null-radio RX start gate. No OCUDU libraries are linked.

#include "external/proto-ru/lib/radio/null/null_rx_gate.h"

#include <cstdio>
#include <cstdlib>

using ocudu::null_rx_gate;

static int failures = 0;

#define CHECK(cond)                                                                                                    \
  do {                                                                                                                 \
    if (!(cond)) {                                                                                                     \
      std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                                             \
      ++failures;                                                                                                      \
    }                                                                                                                  \
  } while (0)

static null_rx_gate make_gate(int target, unsigned stable)
{
  return null_rx_gate(null_rx_gate::configuration{target, stable, 5120});
}

int main()
{
  {
    // Legacy: no gate.
    null_rx_gate g = make_gate(-1, 100);
    CHECK(g.update(0, 0, false, true) == null_rx_gate::action::play);
    CHECK(g.started());
  }

  {
    // Stable delta of 2 for 3 slots arms; marker is still required.
    null_rx_gate g = make_gate(10, 3);
    CHECK(g.update(5, 3, false, true) == null_rx_gate::action::hold);
    CHECK(g.stable_count() == 1);
    CHECK(g.update(6, 4, false, true) == null_rx_gate::action::hold);
    CHECK(g.stable_count() == 2);
    CHECK(!g.armed());
    CHECK(g.update(7, 5, false, true) == null_rx_gate::action::hold);
    CHECK(g.armed());
    CHECK(g.update(8, 6, true, true) == null_rx_gate::action::hold);
    CHECK(!g.started());
    // Mid-slot call at the target must not start.
    CHECK(g.update(10, 8, true, false) == null_rx_gate::action::hold);
    CHECK(!g.started());
    // First call at the target slot boundary starts.
    CHECK(g.update(10, 8, true, true) == null_rx_gate::action::play);
    CHECK(g.started());
    CHECK(g.started_slot() == 10);
  }

  {
    // A delta outlier resets the stable counter and disarms.
    null_rx_gate g = make_gate(20, 3);
    CHECK(g.update(1, 1, true, true) == null_rx_gate::action::hold);
    CHECK(g.update(2, 2, true, true) == null_rx_gate::action::hold);
    CHECK(g.update(3, 8, true, true) == null_rx_gate::action::hold);
    CHECK(g.stable_count() == 1);
    CHECK(!g.armed());
    CHECK(g.update(4, 4, true, true) == null_rx_gate::action::hold);
    CHECK(g.update(5, 5, true, true) == null_rx_gate::action::hold);
    CHECK(g.update(6, 6, true, true) == null_rx_gate::action::hold);
    CHECK(g.armed());
  }

  {
    // Target passed before the marker appears: fail closed.
    null_rx_gate g = make_gate(7, 3);
    CHECK(g.update(5, 5, true, true) == null_rx_gate::action::hold);
    CHECK(g.update(6, 6, true, true) == null_rx_gate::action::hold);
    CHECK(g.update(7, 7, false, true) == null_rx_gate::action::hold); // marker absent
    CHECK(g.armed());
    CHECK(g.update(8, 8, true, true) == null_rx_gate::action::hold);
    CHECK(g.missed());
    CHECK(g.update(9, 9, true, true) == null_rx_gate::action::hold);
    CHECK(!g.started());
  }

  {
    // No consumption before the stable window is satisfied even at the target.
    null_rx_gate g = make_gate(3, 5);
    CHECK(g.update(3, 3, true, true) == null_rx_gate::action::hold);
    CHECK(!g.armed());
    CHECK(!g.started());
  }

  if (failures == 0) {
    std::printf("null_rx_gate: PASS\n");
    return 0;
  }
  std::printf("null_rx_gate: FAIL (%d)\n", failures);
  return 1;
}
