#!/usr/bin/env python3
"""Dependency-free pcap/pcapng reader and OFH downlink Control-Plane scanner.

Only the fields the golden harness needs are decoded: the wire slot (SFN mod 256, slot in frame) and the data
direction. The Open Fronthaul radio-application header layout is fixed (4 bytes after the eCPRI common + RTC/SEQ
header); see external/proto-ru/lib/ofh/serdes/ofh_cplane_message_decoder_impl.cpp.
"""
from __future__ import annotations

import struct
from typing import Iterator

SLOTS_PER_FRAME = 20  # 30 kHz: 10 subframes x 2 slots
OFH_PERIOD = 5120  # 256 SFN x 20 slots
SLOT_SECONDS = 0.0005


def iter_frames(path: str) -> Iterator[tuple[float, bytes]]:
    with open(path, "rb") as f:
        magic = f.read(4)
        if len(magic) < 4:
            return
        if magic == b"\x0a\x0d\x0d\x0a":
            yield from _pcapng(f)
        else:
            yield from _pcap(f, magic)


def _pcap(f, magic: bytes) -> Iterator[tuple[float, bytes]]:
    if magic in (b"\xa1\xb2\xc3\xd4", b"\xa1\xb2\x3c\x4d"):
        endian = ">"
        nano = magic == b"\xa1\xb2\x3c\x4d"
    elif magic in (b"\xd4\xc3\xb2\xa1", b"\x4d\x3c\xb2\xa1"):
        endian = "<"
        nano = magic == b"\x4d\x3c\xb2\xa1"
    else:
        raise ValueError("not a pcap file")
    geo = f.read(20)
    if len(geo) < 20:
        return
    unit = 1e9 if nano else 1e6
    while True:
        hdr = f.read(16)
        if len(hdr) < 16:
            return
        ts_sec, ts_frac, incl, _orig = struct.unpack(endian + "IIII", hdr)
        data = f.read(incl)
        if len(data) < incl:
            return
        yield ts_sec + ts_frac / unit, data


def _pcapng(f) -> Iterator[tuple[float, bytes]]:
    hdr = f.read(8)
    if len(hdr) < 8:
        return
    bom = hdr[4:8]
    if bom == b"\x4d\x3c\x2b\x1a":
        endian = "<"
    elif bom == b"\x1a\x2b\x3c\x4d":
        endian = ">"
    else:
        raise ValueError("bad pcapng byte-order magic")
    shb_len = struct.unpack(endian + "I", hdr[:4])[0]
    if shb_len < 28:
        raise ValueError("bad pcapng section header")
    f.read(shb_len - 12)

    ifaces: list[int] = []
    while True:
        bh = f.read(8)
        if len(bh) < 8:
            return
        btype, blen = struct.unpack(endian + "II", bh)
        if blen < 12:
            return
        body = f.read(blen - 8)
        if len(body) < blen - 8:
            return
        if btype == 0x00000001:  # Interface Description Block
            tsresol = 1_000_000
            opts = body[8:]
            i = 0
            while i + 4 <= len(opts):
                code, olen = struct.unpack(endian + "HH", opts[i : i + 4])
                if code == 0:
                    break
                if code == 9 and olen >= 1:  # if_tsresol
                    v = opts[i + 4]
                    tsresol = (1 << (v & 0x7F)) if (v & 0x80) else (10**v)
                i += 4 + ((olen + 3) // 4) * 4
            ifaces.append(tsresol)
        elif btype == 0x00000006:  # Enhanced Packet Block
            iface_id, tsh, tsl, caplen, _origlen = struct.unpack(endian + "IIIII", body[:20])
            unit = ifaces[iface_id] if iface_id < len(ifaces) else 1_000_000
            yield ((tsh << 32) | tsl) / unit, body[20 : 20 + caplen]
        elif btype == 0x00000003:  # Simple Packet Block (no timestamp)
            origlen = struct.unpack(endian + "I", body[:4])[0]
            yield 0.0, body[4 : 4 + origlen]


def _header(buf: bytes, mtype: int) -> tuple[int, int] | None:
    """Return (radio-app header offset, direction) for an OFH frame of message type mtype, else None.

    Direction follows the OFH data_direction enum: 0 = uplink, 1 = downlink.
    """
    off = 12
    if len(buf) >= 16 and buf[12:14] == b"\x81\x00":
        off = 16
    if len(buf) < off + 14 or buf[off : off + 2] != b"\xae\xfe":
        return None
    ecpri = off + 2
    if buf[ecpri + 1] != mtype:
        return None
    # Both C-plane (RTC_ID/SEQ_ID) and U-plane (PC_ID/SEQ_ID) carry 4 bytes of eCPRI fields before the OFH header.
    rap = ecpri + 8
    if len(buf) < rap + 4:
        return None
    return rap, buf[rap] >> 7


def _slot(buf: bytes, rap: int) -> int | None:
    sfn = buf[rap + 1]
    subframe = buf[rap + 2] >> 4
    slot_id = ((buf[rap + 2] & 0x0F) << 2) | (buf[rap + 3] >> 6)
    if subframe > 9 or slot_id >= 2:
        return None
    return (sfn * SLOTS_PER_FRAME + subframe * 2 + slot_id) % OFH_PERIOD


def cplane(buf: bytes) -> tuple[int, int] | None:
    """Return (wire slot mod 5120, direction) for an OFH Control-Plane frame, else None."""
    hdr = _header(buf, 2)
    if hdr is None:
        return None
    slot = _slot(buf, hdr[0])
    return None if slot is None else (slot, hdr[1])


def uplane(buf: bytes) -> tuple[int, int] | None:
    """Return (wire slot mod 5120, direction) for an OFH User-Plane frame, else None."""
    hdr = _header(buf, 0)
    if hdr is None:
        return None
    slot = _slot(buf, hdr[0])
    return None if slot is None else (slot, hdr[1])
