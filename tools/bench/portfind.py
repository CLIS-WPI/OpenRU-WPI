#!/usr/bin/env python3
"""Port finder analysis: tone level over a fresh baseline per (UHD channel, HackRF).

    portfind.py <capture-dir> <serial-suffix> [<serial-suffix> ...]

Captures (HackRF cs8, 20 Msps, centred on the tone LO): pf_base_c<ch>_<sfx>.cs8 taken right before the tone on
channel <ch>, and pf_tone_c<ch>_<sfx>.cs8 during it. The tone sits +1 MHz from the LO (uhd_one_tone).
Prints one row per channel: tone dB over that HackRF's baseline and the tone level in dBFS.
"""
import os
import sys

import numpy as np

FS, N = 20e6, 8192
TONE_WIN_HZ = (0.85e6, 1.15e6)
FULL_SCALE = 2 * 127.0 ** 2


def spectrum(x):
    """Mean Hann-windowed power spectrum (fftshifted) of complex samples."""
    seg = x[: (len(x) // N) * N].reshape(-1, N) * np.hanning(N)
    return np.mean(np.abs(np.fft.fftshift(np.fft.fft(seg, axis=1), axes=1)) ** 2, axis=0)


def load_cs8(path):
    return np.fromfile(path, np.int8).astype(np.float32).view(np.complex64)


def tone_over_baseline(base, tone):
    """(dB over the baseline median, dBFS) of the strongest bin in the tone window."""
    f = (np.arange(N) - N // 2) * FS / N
    win = (f > TONE_WIN_HZ[0]) & (f < TONE_WIN_HZ[1])
    pb, pt = spectrum(base), spectrum(tone)
    i = int(np.argmax(np.where(win, pt, 0)))
    cg = np.sum(np.hanning(N)) ** 2
    return 10 * np.log10(pt[i] / np.median(pb)), 10 * np.log10(pt[i] / cg / FULL_SCALE)


def main(argv):
    if len(argv) < 3:
        sys.exit(__doc__)
    d, sfx = argv[1], argv[2:]
    print("cells: tone dB over that HackRF's fresh baseline (tone level in dBFS)")
    print(f"{'UHD channel':<12}" + "".join(f"{'HackRF ...' + s:>26}" for s in sfx))
    for ch in range(4):
        cells = []
        for s in sfx:
            b, t = os.path.join(d, f"pf_base_c{ch}_{s}.cs8"), os.path.join(d, f"pf_tone_c{ch}_{s}.cs8")
            if not (os.path.exists(b) and os.path.exists(t)):
                cells.append("no capture")
                continue
            over, dbfs = tone_over_baseline(load_cs8(b), load_cs8(t))
            cells.append(f"{over:+6.1f} dB ({dbfs:+6.1f} dBFS)")
        print(f"{'ch ' + str(ch):<12}" + "".join(f"{c:>26}" for c in cells))


if __name__ == "__main__":
    main(sys.argv)
