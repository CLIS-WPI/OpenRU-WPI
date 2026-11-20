#!/usr/bin/env python3
"""Merge cost-model raw CSVs into one CSV and a compact markdown table.

Raw files are expected to be <isa>.csv with the harness header:
isa,backend,profile,bw_mhz,dft_size,ports,layers,kernel,h2d_p50_ms,
h2d_p99_ms,compute_p50_ms,compute_p99_ms,compute_max_ms,d2h_p50_ms,
d2h_p99_ms,transfer_p50_ms,pass,note
"""
import argparse
import csv
from pathlib import Path

KERNELS = [("ofdm_mod", "OFDM"), ("bfp_compress", "BFP"), ("precoding", "PREC")]
PROFILES = ["20 MHz", "40 MHz", "100 MHz"]
PORTS = [1, 2, 4, 8]


def load(raw: Path):
    rows = {}
    for path in sorted(raw.glob("*.csv")):
        with path.open(newline="") as handle:
            for row in csv.DictReader(handle):
                if row["backend"] == "GPU":
                    row["isa"] = "gpu"
                key = (row["isa"], row["backend"], row["profile"], int(row["ports"]), row["kernel"])
                rows[key] = row
    return rows


def fmt(value, digits=4):
    try:
        number = float(value)
    except (TypeError, ValueError):
        return "-"
    return f"{number:.{digits}f}"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--raw", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()

    rows = load(args.raw)
    if not rows:
        raise SystemExit(f"no CSV rows under {args.raw}")

    args.out.mkdir(parents=True, exist_ok=True)
    merged = args.out / "costmodel.csv"
    fieldnames = [
        "isa", "backend", "profile", "bw_mhz", "dft_size", "ports", "layers",
        "kernel", "h2d_p50_ms", "h2d_p99_ms", "compute_p50_ms",
        "compute_p99_ms", "compute_max_ms", "d2h_p50_ms", "d2h_p99_ms",
        "transfer_p50_ms", "pass", "note",
    ]
    order = {"avx2": 0, "avx512": 1, "gpu": 2}
    with merged.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for key in sorted(rows, key=lambda k: (PROFILES.index(k[2]), k[3], order.get(k[0], 9), k[4])):
            writer.writerow({name: rows[key].get(name, "") for name in fieldnames})

    lines = [
        "# OpenRU low-PHY cost model (per slot)",
        "",
        "Per-slot latency in ms; p50/p99 over the configured iterations. "
        "CPU rows are single-core (`taskset`), GPU rows exclude warmup. "
        "GPU is ISA-independent and was measured on "
        "`GPU-509d8ab3` (H100 NVL).",
        "",
        "| BW | ports | kernel | CPU AVX2 p50 | CPU AVX2 p99 | CPU AVX-512 p50 | CPU AVX-512 p99 | GPU p50 | GPU p99 | GPU H2D p50 | GPU D2H p50 | pass |",
        "|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|:---:|",
    ]
    for profile in PROFILES:
        for ports in PORTS:
            for kernel, label in KERNELS:
                cpu2 = rows.get(("avx2", "CPU", profile, ports, kernel))
                cpu5 = rows.get(("avx512", "CPU", profile, ports, kernel))
                gpu = rows.get(("gpu", "GPU", profile, ports, kernel))
                passed = all(r is not None and r["pass"] == "PASS" for r in (cpu2, cpu5, gpu))
                lines.append(
                    "| {} | {} | {} | {} | {} | {} | {} | {} | {} | {} | {} | {} |".format(
                        profile.replace(" MHz", ""),
                        ports,
                        label,
                        fmt(cpu2 and cpu2["compute_p50_ms"]),
                        fmt(cpu2 and cpu2["compute_p99_ms"]),
                        fmt(cpu5 and cpu5["compute_p50_ms"]),
                        fmt(cpu5 and cpu5["compute_p99_ms"]),
                        fmt(gpu and gpu["compute_p50_ms"]),
                        fmt(gpu and gpu["compute_p99_ms"]),
                        fmt(gpu and gpu["h2d_p50_ms"]),
                        fmt(gpu and gpu["d2h_p50_ms"]),
                        "PASS" if passed else "FAIL",
                    )
                )
    (args.out / "costmodel.md").write_text("\n".join(lines) + "\n")
    print(f"wrote {merged} and {args.out / 'costmodel.md'}")


if __name__ == "__main__":
    main()
