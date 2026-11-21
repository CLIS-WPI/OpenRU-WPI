#!/usr/bin/env python3
"""Generate the 20 MHz PUSCH UL feed, expected grid, and synthetic C-plane pcap."""
from __future__ import annotations

import argparse
import json
import struct
from pathlib import Path

import numpy as np

SCS_KHZ = 30
SLOTS_PER_FRAME = 20
DFT = 768
RB = 51
RE = RB * 12
CP0, CP = 66, 54
SAMPLES = 11520
UL_SLOT_IN_PERIOD = 4
PERIOD = 5
IQ_SCALING = 16


def cplane_payload(sfn: int, slot: int, direction: int, start_symbol: int, nof_symbols: int,
                   nof_prb: int) -> bytes:
    slot_in_sf = slot % 2
    b = [
        (direction << 7) | (1 << 4),                 # direction, payload version, filter
        sfn & 0xFF,
        ((slot // 2) & 0xF) << 4 | ((slot_in_sf >> 2) & 0xF),
        ((slot_in_sf & 0x3) << 6) | (start_symbol & 0x3F),
        1, 1, 0, 0,                                   # sections, section type 1, static BFP9, reserved
        0, 0,                                         # section id / rb / symInc / prb high
        0, nof_prb & 0xFF,                            # prb start, nof prb
        0xFF, 0xF0 | (nof_symbols & 0xF),             # reMask 0xfff, nof symbols
        0, 0,                                         # EF/beam id
    ]
    return bytes(b)


def ecpri_cplane(payload: bytes, seq: int = 0) -> bytes:
    size = len(payload) + 4
    return bytes([0x10, 0x02, (size >> 8) & 0xFF, size & 0xFF]) + struct.pack(">I", seq) + payload


def ether(dst: bytes, src: bytes, payload: bytes) -> bytes:
    return dst + src + b"\xae\xfe" + payload


def write_pcap(path: Path, packets: list[tuple[float, bytes]]) -> None:
    with path.open("wb") as f:
        f.write(struct.pack("<IHHiIII", 0xA1B2C3D4, 2, 4, 0, 0, 65535, 1))
        for ts, frame in packets:
            sec = int(ts)
            usec = int(round((ts - sec) * 1e6))
            f.write(struct.pack("<IIII", sec, usec, len(frame), len(frame)))
            f.write(frame)


def qpsk_grid(rng: np.random.Generator, shape) -> np.ndarray:
    bits = rng.integers(0, 2, size=shape + (2,), dtype=np.int8)
    re = (1 - 2 * bits[..., 0]).astype(np.float32) / np.sqrt(2)
    im = (1 - 2 * bits[..., 1]).astype(np.float32) / np.sqrt(2)
    return (re + 1j * im).astype(np.complex64)


def ofdm_symbol(grid: np.ndarray, cp_len: int) -> np.ndarray:
    freq = np.zeros(DFT, dtype=np.complex64)
    half = RE // 2
    freq[DFT - half:] = grid[:half]
    freq[:half] = grid[half:]
    td = np.fft.ifft(freq) * np.sqrt(DFT)
    return np.concatenate([td[-cp_len:], td])


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--slots", type=int, default=100)
    ap.add_argument("--seed", type=int, default=0xC0FFEE)
    args = ap.parse_args()

    args.out.mkdir(parents=True, exist_ok=True)
    sfn0, slot0 = 100, UL_SLOT_IN_PERIOD
    target = (sfn0 * SLOTS_PER_FRAME + slot0) % 5120

    ul_slots = []
    for i in range(args.slots):
        sfn = sfn0 + (slot0 + i) // SLOTS_PER_FRAME
        slot = (slot0 + i) % SLOTS_PER_FRAME
        if slot % PERIOD == UL_SLOT_IN_PERIOD:
            ul_slots.append((i, sfn, slot))

    rng = np.random.default_rng(args.seed)
    grid = qpsk_grid(rng, (len(ul_slots), 14, 2, RE))
    feed = np.zeros((2, args.slots * SAMPLES), dtype=np.complex64)
    for k, (i, _sfn, _slot) in enumerate(ul_slots):
        off = i * SAMPLES
        cursor = 0
        for sym in range(14):
            cp_len = CP0 if sym == 0 else CP
            for port in range(2):
                td = ofdm_symbol(grid[k, sym, port], cp_len)
                feed[port, off + cursor: off + cursor + len(td)] = td
            cursor += cp_len + DFT

    peak = float(np.max(np.abs(feed))) or 1.0
    scale = 20000.0 / peak
    for port in range(2):
        ci16 = np.empty(feed[port].size * 2, dtype=np.float32)
        ci16[0::2] = np.clip(np.round(feed[port].real * scale), -32768, 32767)
        ci16[1::2] = np.clip(np.round(feed[port].imag * scale), -32768, 32767)
        ci16.astype("<f4").tofile(args.out / f"port{port}.cf32")

    np.savez_compressed(args.out / "expected.npz",
                        slots=np.array([s for _, s, _ in [(a, b, c) for a, b, c in ul_slots]], dtype=np.int32),
                        sfn=np.array([b for _, b, _ in ul_slots], dtype=np.int32),
                        slot=np.array([c for _, _, c in ul_slots], dtype=np.int32),
                        grid=grid, iq_scaling=np.array(IQ_SCALING, dtype=np.int32))

    plan = {
        "profile": "baseline", "bw_mhz": 20, "rb": RB, "fft": DFT, "scs_khz": SCS_KHZ,
        "samples_per_slot": SAMPLES, "cp0": CP0, "cp": CP, "iq_scaling": IQ_SCALING,
        "window_slots": args.slots, "target_du_slot": target,
        "rx_start_stable_slots": 100, "ul_slots": len(ul_slots),
        "ul": [{"sfn": b, "slot": c} for _, b, c in ul_slots],
    }
    (args.out / "plan.json").write_text(json.dumps(plan, indent=2) + "\n")

    dst, src = bytes.fromhex("020000000020"), bytes.fromhex("020000000010")
    packets = [(0.0, ether(dst, src, ecpri_cplane(cplane_payload(sfn0, 0, 1, 0, 14, 0))))]
    for idx, (i, sfn, slot) in enumerate(ul_slots):
        t = i * 0.0005 - 0.002
        if t < 0:
            t = 0.0
        packets.append((t, ether(dst, src, ecpri_cplane(cplane_payload(sfn, slot, 0, 0, 14, RB), idx))))
    write_pcap(args.out / "ul_synthetic.pcapng", packets)

    print(json.dumps({"out": str(args.out), "target_du_slot": target, "ul_slots": len(ul_slots),
                      "feed_bytes": (args.out / "port0.cf32").stat().st_size}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
