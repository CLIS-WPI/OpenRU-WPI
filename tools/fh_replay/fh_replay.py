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
import sys
import time


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--pcap", required=True, help="Input .pcapng")
    ap.add_argument("--iface", required=True, help="Egress interface (fh bridge)")
    ap.add_argument("--dst-mac", default="", help="Rewrite destination MAC")
    ap.add_argument("--src-mac", default="", help="Rewrite source MAC")
    ap.add_argument("--vlan", type=int, default=-1, help="VLAN tag (-1=untagged)")
    ap.add_argument("--rate", type=float, default=1.0, help="Timing scale (1=realtime, 0=asap)")
    ap.add_argument("--count", type=int, default=0, help="Max packets (0=all)")
    ap.add_argument("--dry-run", action="store_true", help="Parse only; do not send")
    args = ap.parse_args()

    try:
        from scapy.all import Ether, Dot1Q, PcapReader, sendp  # type: ignore
    except ImportError:
        print("FAIL: scapy not installed (pip install scapy)", file=sys.stderr)
        return 2

    n = 0
    prev_t = None
    with PcapReader(args.pcap) as reader:
        for pkt in reader:
            if args.count and n >= args.count:
                break
            t = float(pkt.time)
            if prev_t is not None and args.rate > 0:
                dt = (t - prev_t) / args.rate
                if dt > 0:
                    time.sleep(dt)
            prev_t = t

            if Ether not in pkt:
                continue
            eth = pkt[Ether]
            if args.dst_mac:
                eth.dst = args.dst_mac
            if args.src_mac:
                eth.src = args.src_mac
            if args.vlan >= 0:
                if Dot1Q in eth:
                    eth[Dot1Q].vlan = args.vlan
                else:
                    eth = Ether(dst=eth.dst, src=eth.src) / Dot1Q(vlan=args.vlan) / eth.payload

            if not args.dry_run:
                sendp(eth, iface=args.iface, verbose=False)
            n += 1

    print(f"fh_replay: sent={n} pcap={args.pcap} iface={args.iface} rate={args.rate} dry_run={args.dry_run}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
