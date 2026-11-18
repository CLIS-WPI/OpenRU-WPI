#!/usr/bin/env python3
"""Replay OFH pcapng onto a bridge with original inter-packet timing.

Usage:
  fh_replay.py --pcap testdata/pcap/baseline.pcapng --iface fh-veth \\
               --dst-mac 02:00:00:00:00:20 --src-mac 02:00:00:00:00:10 \\
               --rate 1.0

Requires: scapy (and CAP_NET_RAW / root for live send).
"""
from __future__ import annotations

import argparse
import socket
import struct
import sys
import time


def _iter_dpkt(path):
    import dpkt

    with open(path, "rb") as f:
        magic = f.read(4)
    if magic == b"\x0a\x0d\x0d\x0a":
        with open(path, "rb") as f:
            for ts, buf in dpkt.pcapng.Reader(f):
                yield float(ts), buf
    else:
        with open(path, "rb") as f:
            for ts, buf in dpkt.pcap.Reader(f):
                yield float(ts), buf


def _iter_scapy(path):
    from scapy.all import Ether, PcapReader

    with PcapReader(path) as reader:
        for pkt in reader:
            if Ether not in pkt:
                continue
            yield float(pkt.time), bytes(pkt[Ether])


GPS_EPOCH_OFFSET_NS = (315964800 - 18) * 1_000_000_000
OFH_PERIOD = 5120
SLOTS_PER_FRAME = 20  # 30 kHz: 10 subframes * 2 slots
SLOT_NS = 500_000


def _cplane_slot(buf) -> int | None:
    """Return the OFH wire slot number of a DL C-plane frame, else None."""
    off = 12
    if len(buf) >= 16 and buf[12:14] == b"\x81\x00":
        off = 16
    if len(buf) < off + 14 or buf[off : off + 2] != b"\xae\xfe":
        return None
    ecpri = off + 2
    if buf[ecpri + 1] != 2:
        return None
    rap = ecpri + 8
    if len(buf) < rap + 4:
        return None
    if buf[rap] >> 7 != 1:  # 1 = downlink (data_direction: uplink=0, downlink=1)
        return None
    sfn = buf[rap + 1]
    subframe = buf[rap + 2] >> 4
    slot_id = ((buf[rap + 2] & 0x0F) << 2) | (buf[rap + 3] >> 6)
    return (sfn * SLOTS_PER_FRAME + subframe * 2 + slot_id) % OFH_PERIOD


STARTUP_MARGIN_SLOTS = 100  # 50 ms so the first frames have future deadlines


def _align_target(slot_mod: int, lead_us: float) -> float:
    """Monotonic perf deadline of the DL C-plane for `slot_mod`, exactly `lead_us` before its air slot.

    The lead is NOT rounded to whole slots: the DU T1a window is ~200 us wide and the U-plane follows the C-plane by
    ~200 us + the replay U-plane delay. Rounding 2235 us down to 2000 us moved the next C-plane 235 us earlier than
    the U-plane burst tail and the RU mislabelled the tail into the next slot (+1 slot). The caller offsets the first
    frame from this deadline.
    """
    now_gps_ns = time.time_ns() - GPS_EPOCH_OFFSET_NS
    now_slot = now_gps_ns // SLOT_NS
    delta = (slot_mod - (now_slot % OFH_PERIOD)) % OFH_PERIOD
    if delta < STARTUP_MARGIN_SLOTS:
        delta += OFH_PERIOD
    air_unix_ns = (now_slot + delta) * SLOT_NS + GPS_EPOCH_OFFSET_NS
    target_unix_ns = air_unix_ns - int(round(lead_us * 1000.0))
    return time.perf_counter() + (target_unix_ns - time.time_ns()) * 1e-9


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--pcap", required=True, help="Input .pcapng")
    ap.add_argument("--iface", required=True, help="Egress interface (fh bridge)")
    ap.add_argument("--dst-mac", default="", help="Rewrite destination MAC")
    ap.add_argument("--src-mac", default="", help="Rewrite source MAC")
    ap.add_argument(
        "--only-dst-mac",
        default="",
        help="Keep only frames whose (pre-rewrite) Ethernet dst matches (e.g. RU MAC)",
    )
    ap.add_argument("--vlan", type=int, default=-1, help="VLAN tag (-1=untagged)")
    ap.add_argument("--rate", type=float, default=1.0, help="Timing scale (1=realtime, 0=asap)")
    ap.add_argument(
        "--uplane-delay-us",
        type=float,
        default=0.0,
        help="Delay eCPRI IQ (User-Plane, type 0) frames by this many microseconds "
        "relative to the C-plane, without moving the C-plane (replay-only).",
    )
    ap.add_argument(
        "--lead-us",
        type=float,
        default=0.0,
        help="Send each frame this many microseconds ahead of its pcap time "
        "(compensates replay socket/bridge latency; keeps relative timing).",
    )
    ap.add_argument(
        "--align-cplane-lead-us",
        type=float,
        required=True,
        help="C-plane lead in microseconds before the air slot, from the RU profile "
        "t2a_min_cp_dl (scripts pass the window JSON lead); required so no host-specific "
        "constant is baked in. Negative disables the aligner.",
    )
    ap.add_argument(
        "--start-marker",
        default="",
        help="Create this file just before the first frame is sent, arming the RU dump gate.",
    )
    ap.add_argument(
        "--report-send-errors",
        action="store_true",
        help="Collect actual-send minus scheduled-time per frame and print p50/p90/p99/max (positive = late).",
    )
    ap.add_argument("--count", type=int, default=0, help="Max packets (0=all)")
    ap.add_argument("--dry-run", action="store_true", help="Parse only; do not send")
    args = ap.parse_args()

    def norm_mac(m: str) -> str:
        return m.strip().lower().replace("-", ":")

    only_dst = norm_mac(args.only_dst_mac) if args.only_dst_mac else ""
    dst_b = bytes.fromhex(only_dst.replace(":", "")) if only_dst else b""
    src_b = bytes.fromhex(norm_mac(args.src_mac).replace(":", "")) if args.src_mac else b""
    dst_rw = bytes.fromhex(norm_mac(args.dst_mac).replace(":", "")) if args.dst_mac else b""

    n = 0
    skipped = 0
    t0_pcap = None
    t0_wall = None
    lead_s = args.lead_us * 1e-6
    uplane_delay_s = args.uplane_delay_us * 1e-6
    marker_armed = False
    send_errors = [] if args.report_send_errors else None
    sock = None
    if not args.dry_run:
        sock = socket.socket(socket.AF_PACKET, socket.SOCK_RAW)
        sock.bind((args.iface, 0))

    try:
        import itertools

        try:
            import dpkt  # noqa: F401

            frames = _iter_dpkt(args.pcap)
            engine = "dpkt"
        except ImportError:
            frames = _iter_scapy(args.pcap)
            engine = "scapy"

        # Peek at the head of the capture to find the first DL C-plane, whose wire slot anchors the replay timeline to
        # the wall-clock GPS slot the live O-DU was transmitting on (see ru_emulator_gps_slot_aligner).
        cplane_t = None
        cplane_slot = None
        cplane_perf = None
        head = []
        t_first = None
        if args.rate > 0 and args.align_cplane_lead_us >= 0 and not args.dry_run:
            for t, buf in frames:
                if t_first is None:
                    t_first = t
                head.append((t, buf))
                slot = _cplane_slot(buf)
                if slot is not None:
                    cplane_t = t
                    cplane_slot = slot
                    break
                if len(head) >= 512:
                    break
            frames = itertools.chain(head, frames)
            if cplane_slot is not None:
                cplane_perf = _align_target(cplane_slot, args.align_cplane_lead_us)

        for t, buf in frames:
            if args.count and n >= args.count:
                break
            if len(buf) < 14:
                continue
            if dst_b and buf[0:6] != dst_b:
                skipped += 1
                continue
            if t0_pcap is None:
                t0_pcap = t
                if cplane_perf is not None:
                    t0_wall = cplane_perf - (cplane_t - t) / args.rate
                else:
                    t0_wall = time.perf_counter()
            if args.start_marker and not marker_armed and not args.dry_run:
                try:
                    with open(args.start_marker, "w"):
                        pass
                except OSError as exc:
                    print(f"fh_replay: cannot create start marker {args.start_marker}: {exc}", file=sys.stderr)
                    return 2
                marker_armed = True
            if args.rate > 0:
                target = t0_wall + (t - t0_pcap) / args.rate - lead_s
                if uplane_delay_s and len(buf) > 15 and buf[12:14] == b"\xae\xfe" and buf[15] == 0:
                    target += uplane_delay_s
                delay = target - time.perf_counter()
                if delay > 0.0002:
                    time.sleep(delay - 0.00015)
                while time.perf_counter() < target:
                    pass
            frame = bytearray(buf)
            if dst_rw:
                frame[0:6] = dst_rw
            if src_b:
                frame[6:12] = src_b
            if args.vlan >= 0 and frame[12:14] == b"\x81\x00":
                struct.pack_into(">H", frame, 14, args.vlan)
            if sock is not None:
                sock.send(frame)
            if send_errors is not None and args.rate > 0:
                send_errors.append(time.perf_counter() - target)
            n += 1
    finally:
        if sock is not None:
            sock.close()

    if send_errors:
        errs = sorted(send_errors)
        cnt = len(errs)

        def pct(q: float) -> float:
            return errs[min(cnt - 1, int(q * (cnt - 1)))]

        late200 = sum(1 for e in errs if e > 200e-6)
        late500 = sum(1 for e in errs if e > 500e-6)
        late1ms = sum(1 for e in errs if e > 1e-3)
        print(
            f"fh_replay: send_error_us n={cnt} min={errs[0]*1e6:.1f} p50={pct(0.5)*1e6:.1f} "
            f"p90={pct(0.9)*1e6:.1f} p99={pct(0.99)*1e6:.1f} max={errs[-1]*1e6:.1f} "
            f"late>200us={late200} late>500us={late500} late>1ms={late1ms}"
        )

    print(
        f"fh_replay: sent={n} skipped={skipped} pcap={args.pcap} "
        f"iface={args.iface} rate={args.rate} lead_us={args.lead_us:g} "
        f"engine={engine} dry_run={args.dry_run} "
        f"align_slot={cplane_slot} align_lead_us={args.align_cplane_lead_us:g}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
