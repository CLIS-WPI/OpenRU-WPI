#!/usr/bin/env python3
"""Compute the golden capture window for a pcap.

The window starts at the first frame boundary (slot 0) at least two frames after the first downlink Control-Plane in
the capture, so the golden is anchored to the pcap content rather than to SFN 0 (SFN wraps every 10.24 s, while the
b40/b100 captures are shorter). The same start slot is what the RU dump gate waits for, which makes the dump
deterministic and independent of cold-start timing.

The expected non-empty slots are the downlink User-Plane slots inside the window, taken from the pcap itself (SSB +
PDCCH/PDSCH the live O-DU actually transmitted), not from the Control-Plane schedule (which includes empty sections).

Exit status: 0 window fits, 2 pcap cannot contain the window, 1 parse error.
"""
from __future__ import annotations

import argparse
import json
import re
import sys

from ofh_scan import OFH_PERIOD, SLOT_SECONDS, SLOTS_PER_FRAME, cplane, iter_frames, uplane

MIN_LEAD_SLOTS = 2 * SLOTS_PER_FRAME  # at least two frames after the first DL C-plane
RU_MAC = "02:00:00:00:00:20"


def _mac(s: str) -> bytes:
    return bytes.fromhex(s.replace(":", "").replace("-", "").lower())


def parse_dl_ports(du_config: str) -> list[int]:
    """Return the O-DU's configured downlink ports from ru_ofh.cells[0].dl_port_id."""
    text = open(du_config).read()
    m = re.search(r"^\s*dl_port_id\s*:\s*\[([^\]]*)\]", text, re.MULTILINE)
    if not m:
        raise ValueError(f"{du_config}: no ru_ofh.cells.dl_port_id")
    return [int(v) for v in m.group(1).split(",") if v.strip()]


def _uplane_header(buf: bytes) -> tuple[int, int]:
    """Return (radio-app header offset, eAxC) for an OFH User-Plane frame."""
    from ofh_scan import _header

    rap = _header(buf, 0)[0]
    return rap, (int(buf[rap - 4]) << 8) | int(buf[rap - 3])


def _uplane_payload_nonzero(buf: bytes) -> bool:
    """True when the User-Plane IQ payload carries energy (zero PDSCH sections are all-zero bytes)."""
    return any(buf[40:])


def analyze(pcap: str, window_slots: int, t2a_us: float, dst_mac: str,
            uplane_delay_us: float = 250.0, dl_ports: list[int] | None = None) -> dict:
    dst = _mac(dst_mac) if dst_mac else b""
    t_first = None
    t_last = None
    first_slot = None
    first_slot_t = None
    last_cplane_slot = None
    cplanes: list[tuple[float, int]] = []
    for t, buf in iter_frames(pcap):
        if t <= 0:  # skip blocks without a timestamp
            continue
        if t_first is None:
            t_first = t
        t_last = t
        if dst and buf[:6] != dst:
            continue
        info = cplane(buf)
        if info is None or info[1] != 1:  # 1 = downlink (data_direction: uplink=0, downlink=1)
            continue
        cplanes.append((t, info[0]))
        if first_slot is None:
            first_slot, first_slot_t = info[0], t
        last_cplane_slot = info[0]
    if first_slot is None:
        raise ValueError(f"{pcap}: no downlink Control-Plane found")

    start_frame = (first_slot + MIN_LEAD_SLOTS + SLOTS_PER_FRAME - 1) // SLOTS_PER_FRAME
    start_du = (start_frame * SLOTS_PER_FRAME) % OFH_PERIOD
    delta = (start_du - first_slot) % OFH_PERIOD
    if delta < MIN_LEAD_SLOTS:
        start_du = (start_du + OFH_PERIOD) % OFH_PERIOD
        delta = (start_du - first_slot) % OFH_PERIOD

    t2a_s = t2a_us * 1e-6
    start_air = first_slot_t + t2a_s + delta * SLOT_SECONDS
    end_air = start_air + window_slots * SLOT_SECONDS
    start_off = start_air - t_first
    end_send = end_air - t2a_s
    end_send_off = end_send - t_first
    # Only the first occurrence of this window in the capture is the one the replay sends during the dump; later
    # SFN periods may carry different live scheduling.
    start_cplane_t = min(t for t, slot in cplanes if slot == start_du)
    expected_t0 = start_cplane_t
    expected_t1 = start_cplane_t + (window_slots + 2) * SLOT_SECONDS
    fits = (start_off >= 0.0) and (end_send <= t_last + SLOT_SECONDS) and (expected_t1 <= t_last)
    expected: set[int] = set()
    expected_by_port: dict[int, set[int]] = {}
    ports_seen: set[int] = set()
    last_u_t = None
    for t, buf in iter_frames(pcap):
        if t <= 0 or t < expected_t0 or t > expected_t1 or (dst and buf[:6] != dst):
            continue
        info = uplane(buf)
        if info is None or info[1] != 1:  # downlink only (1 = downlink)
            continue
        off = (info[0] - start_du) % OFH_PERIOD
        if off >= window_slots:
            continue
        _rap, eaxc = _uplane_header(buf)
        ports_seen.add(eaxc)
        last_u_t = t
        # A configured DL port can be SSB-only (the no-UE cell's PDSCH is single-layer): the port's
        # expectation is the set of slots whose own U-plane payload is non-zero, not every DL C-plane slot.
        if _uplane_payload_nonzero(buf):
            expected.add(off)
            expected_by_port.setdefault(eaxc, set()).add(off)
    expected = sorted(expected)
    configured = sorted(dl_ports) if dl_ports else sorted(ports_seen)
    silent_ports = [p for p in configured if not expected_by_port.get(p)]
    unexpected_ports = sorted(ports_seen - set(configured))

    return {
        "pcap": pcap,
        "dst_mac": dst_mac,
        "window_slots": window_slots,
        "first_dl_cplane_slot": first_slot,
        "first_dl_cplane_offset_s": round(first_slot_t - t_first, 6),
        "last_dl_cplane_slot": last_cplane_slot,
        "start_du": start_du,
        "start_du_sfn": start_du // SLOTS_PER_FRAME,
        "start_du_slot": start_du % SLOTS_PER_FRAME,
        "start_du_delta_slots": delta,
        "lead_us": t2a_us,
        "uplane_delay_us": uplane_delay_us,
        "pcap_span_s": round(t_last - t_first, 6),
        "start_air_offset_s": round(start_off, 6),
        "end_air_offset_s": round(start_off + window_slots * SLOT_SECONDS, 6),
        "end_send_offset_s": round(end_send_off, 6),
        "last_uplane_offset_s": round((last_u_t or 0.0) - t_first, 6),
        "expected_window_s": round(expected_t1 - expected_t0, 6),
        "expected_uplane_slots": expected,
        "expected_uplane_count": len(expected),
        "expected_ports": configured,
        "expected_slots_by_port": {str(p): sorted(offs) for p, offs in expected_by_port.items() if offs},
        "silent_ports": silent_ports,
        "unexpected_ports": unexpected_ports,
        "fits": bool(fits),
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--pcap", required=True)
    ap.add_argument("--window-slots", type=int, required=True)
    ap.add_argument("--t2a-us", type=float, required=True, help="C-plane lead (RU t2a_min_cp_dl)")
    ap.add_argument("--dst-mac", default=RU_MAC, help="Only count frames to this MAC (empty = all)")
    ap.add_argument("--du-config", required=True, help="O-DU YAML with ru_ofh.cells.dl_port_id")
    ap.add_argument("--uplane-delay-us", type=float, default=250.0,
                    help="Replay sends each U-plane this much later to clear the null radio's C-plane slot-update lag")
    ap.add_argument("--json", default=None, help="Write the result here")
    args = ap.parse_args()

    try:
        info = analyze(
            args.pcap,
            args.window_slots,
            args.t2a_us,
            args.dst_mac,
            args.uplane_delay_us,
            parse_dl_ports(args.du_config),
        )
    except Exception as exc:  # noqa: BLE001
        print(f"golden-window: ERROR {exc}", file=sys.stderr)
        return 1

    text = json.dumps(info, indent=2) + "\n"
    if args.json:
        with open(args.json, "w") as f:
            f.write(text)
    else:
        sys.stdout.write(text)

    if info["expected_uplane_count"] == 0:
        print(
            f"golden-window: FAIL {args.pcap} has no downlink User-Plane in the window "
            f"({info['start_du_sfn']}.{info['start_du_slot']} + {args.window_slots} slots); "
            f"check MTU 9000 and that the O-DU sent data",
            file=sys.stderr,
        )
        return 2
    if not info["fits"]:
        print(
            f"golden-window: FAIL window {args.window_slots} slots from DU slot {info['start_du']} "
            f"({info['start_du_sfn']}.{info['start_du_slot']}) needs pcap up to "
            f"{info['end_send_offset_s']:.3f}s but pcap span is {info['pcap_span_s']:.3f}s; "
            f"capture longer or shrink the window",
            file=sys.stderr,
        )
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
