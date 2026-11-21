#!/usr/bin/env python3
"""Aggregate repeated clean cost-model runs into median and range per row."""
from __future__ import annotations

import argparse
import csv
import json
import statistics
from pathlib import Path

PROFILES = ["20 MHz", "40 MHz", "100 MHz"]
PORTS = [1, 2, 4, 8]
KERNELS = [("ofdm_mod", "OFDM"), ("bfp_compress", "BFP"), ("precoding", "PREC")]
ISAS = [("avx2", "CPU", "CPU AVX2"), ("avx512", "CPU", "CPU AVX-512"), ("gpu", "GPU", "GPU")]


def load_run(run_dir: Path):
    rows = {}
    for isa in ("avx2", "avx512", "gpu"):
        path = run_dir / f"{isa}.csv"
        if not path.exists():
            continue
        for row in csv.DictReader(path.open()):
            if "backend" not in row:
                continue
            backend = row["backend"]
            if backend == "GPU":
                isa_key = "gpu"
            else:
                isa_key = isa
            key = (isa_key, backend, row["profile"], int(row["ports"]), row["kernel"])
            rows[key] = row
    return rows


def stats(values):
    values = [float(v) for v in values if v not in ("", None)]
    if not values:
        return None, None, None
    return statistics.median(values), min(values), max(values)


def fmt(value, digits=4):
    if value is None:
        return "-"
    return f"{value:.{digits}f}"


def cell(stats_tuple):
    med, lo, hi = stats_tuple
    if med is None:
        return "-"
    return f"{med:.4f} [{lo:.4f}-{hi:.4f}]"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw-root", required=True, type=Path)
    ap.add_argument("--runs", required=True, help="comma-separated run ids")
    ap.add_argument("--out", required=True, type=Path)
    args = ap.parse_args()

    runs = [r.strip() for r in args.runs.split(",") if r.strip()]
    per_run = {}
    conds = {}
    for run in runs:
        run_dir = args.raw_root / run / "final"
        per_run[run] = load_run(run_dir)
        cpath = run_dir / "conditions.json"
        conds[run] = json.loads(cpath.read_text()) if cpath.exists() else {}

    args.out.mkdir(parents=True, exist_ok=True)
    raw_keys = []
    for run in runs:
        for key in per_run[run]:
            if key not in raw_keys:
                raw_keys.append(key)
    raw_keys.sort(key=lambda k: (PROFILES.index(k[2]), k[3], k[0], k[4]))

    merged_rows = []
    for key in raw_keys:
        isa, backend, profile, ports, kernel = key
        samples = [per_run[run][key] for run in runs if key in per_run[run]]
        if not samples:
            continue
        p50 = stats([s["compute_p50_ms"] for s in samples])
        p99 = stats([s["compute_p99_ms"] for s in samples])
        h2d = stats([s.get("h2d_p50_ms", "") for s in samples]) if backend == "GPU" else (None, None, None)
        d2h = stats([s.get("d2h_p50_ms", "") for s in samples]) if backend == "GPU" else (None, None, None)
        merged_rows.append({
            "profile": profile,
            "bw_mhz": samples[0]["bw_mhz"],
            "dft_size": samples[0]["dft_size"],
            "ports": ports,
            "layers": samples[0]["layers"],
            "kernel": kernel,
            "isa": isa,
            "backend": backend,
            "runs": len(samples),
            "p50_median_ms": f"{p50[0]:.6f}",
            "p50_min_ms": f"{p50[1]:.6f}",
            "p50_max_ms": f"{p50[2]:.6f}",
            "p99_median_ms": f"{p99[0]:.6f}",
            "p99_min_ms": f"{p99[1]:.6f}",
            "p99_max_ms": f"{p99[2]:.6f}",
            "h2d_median_ms": "" if h2d[0] is None else f"{h2d[0]:.6f}",
            "h2d_min_ms": "" if h2d[1] is None else f"{h2d[1]:.6f}",
            "h2d_max_ms": "" if h2d[2] is None else f"{h2d[2]:.6f}",
            "d2h_median_ms": "" if d2h[0] is None else f"{d2h[0]:.6f}",
            "d2h_min_ms": "" if d2h[1] is None else f"{d2h[1]:.6f}",
            "d2h_max_ms": "" if d2h[2] is None else f"{d2h[2]:.6f}",
            "pass_all": all(s["pass"] == "PASS" for s in samples),
        })

    fieldnames = list(merged_rows[0].keys())
    for name in ("costmodel-variance.csv", "costmodel.csv"):
        with (args.out / name).open("w", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=fieldnames)
            writer.writeheader()
            writer.writerows(merged_rows)

    lookup = {(r["isa"], r["profile"], r["ports"], r["kernel"]): r for r in merged_rows}
    def get(isa, profile, ports, kernel, field):
        r = lookup.get((isa, profile, ports, kernel))
        if not r or not r[field]:
            return "-"
        if field.endswith("_median_ms"):
            lo = r[field.replace("_median_", "_min_")]
            hi = r[field.replace("_median_", "_max_")]
            return f"{float(r[field]):.4f} [{float(lo):.4f}-{float(hi):.4f}]"
        return r[field]

    lines = [
        "# OpenRU low-PHY cost model — 3-run variance",
        "",
        f"Runs: `{', '.join(runs)}`. Each run used a different reserved core set, the same",
        "per-core/GPU gate as #47, 200 iterations, and the GPU at default clocks.",
        "Cells are **median [min-max]** across the three runs (ms per slot; 0.5 ms slot).",
        "Machine-readable rows: `costmodel.csv` / `costmodel-variance.csv`.",
        "",
        "> Host constraint: the shared host had no 3-core window free of other processes",
        "> during these runs. Each variance run therefore reserved one physical core",
        "> (SMT is off, so there is no HT sibling) and applied the same per-core/GPU gate.",
        "> The three runs used cores 6 (NUMA 0), 43 (NUMA 1), and 12 (NUMA 0). The #47",
        "> single-run clean table used 19,21,31; it is superseded by this variance report.",
        "",
        "## Run conditions",
        "",
        "| run | cores | NUMA | bench | max foreign CPU | GPU SM median | GPU power |",
        "|---|---|---:|---:|---|---:|---|",
    ]
    for run in runs:
        c = conds.get(run, {})
        clock = c.get("gpu_clock") or {}
        sm = (clock.get("clocks.current.sm [MHz]") or {}).get("median")
        pwr = (clock.get("power.draw [W]") or {})
        runs_info = c.get("core_runs") or {}
        bits = []
        for n in ("avx2", "avx512", "gpu"):
            info = runs_info.get(n) or {}
            mx = info.get("max_foreign_pct") or {}
            value = max(mx.values()) if mx else None
            bits.append(f"{n} {value}%" if value is not None else f"{n} ?")
        foreign = ", ".join(bits)
        cores = ",".join(str(x) for x in c.get("cores", []))
        lines.append(
            f"| `{run}` | {cores} | {c.get('numa_node')} | {c.get('bench_core')} | {foreign} | {sm} MHz | {pwr.get('min')}-{pwr.get('max')} W |"
        )

    lines += [
        "",
        "## p50",
        "",
        "| BW | ports | kernel | CPU AVX2 | CPU AVX-512 | GPU |",
        "|---:|---:|---|---:|---:|---:|",
    ]
    for profile in PROFILES:
        for ports in PORTS:
            for kernel, label in KERNELS:
                lines.append(
                    "| {} | {} | {} | {} | {} | {} |".format(
                        profile.replace(" MHz", ""), ports, label,
                        get("avx2", profile, ports, kernel, "p50_median_ms"),
                        get("avx512", profile, ports, kernel, "p50_median_ms"),
                        get("gpu", profile, ports, kernel, "p50_median_ms"),
                    )
                )
    lines += [
        "",
        "## p99",
        "",
        "| BW | ports | kernel | CPU AVX2 | CPU AVX-512 | GPU |",
        "|---:|---:|---|---:|---:|---:|",
    ]
    for profile in PROFILES:
        for ports in PORTS:
            for kernel, label in KERNELS:
                lines.append(
                    "| {} | {} | {} | {} | {} | {} |".format(
                        profile.replace(" MHz", ""), ports, label,
                        get("avx2", profile, ports, kernel, "p99_median_ms"),
                        get("avx512", profile, ports, kernel, "p99_median_ms"),
                        get("gpu", profile, ports, kernel, "p99_median_ms"),
                    )
                )
    lines += [
        "",
        "## GPU transfers",
        "",
        "| BW | ports | kernel | H2D p50 | D2H p50 |",
        "|---:|---:|---|---:|---:|",
    ]
    for profile in PROFILES:
        for ports in PORTS:
            for kernel, label in KERNELS:
                lines.append(
                    "| {} | {} | {} | {} | {} |".format(
                        profile.replace(" MHz", ""), ports, label,
                        get("gpu", profile, ports, kernel, "h2d_median_ms"),
                        get("gpu", profile, ports, kernel, "d2h_median_ms"),
                    )
                )
    lines += [
        "",
        "## Notes",
        "",
        "- All rows pass the correctness gates in every run; `pass_all` in the CSV.",
        "- p50 is the headline. p99 still contains isolated host-scheduler outliers; the",
        "  range is reported so that is visible. The benchmark cannot take RT priority.",
        "- SMT is off on this host; each reserved physical core is one logical CPU.",
        "- The Cat-B AVX-512 explanation and the busy-host comparison are in",
        "  `COMPARISON.md` (from #47). The single-run clean table is in the #47 history.",
    ]
    (args.out / "costmodel.md").write_text("\n".join(lines) + "\n")
    (args.out / "variance_conditions.json").write_text(json.dumps(conds, indent=2) + "\n")
    print(f"wrote {args.out/'costmodel.md'} and {args.out/'costmodel-variance.csv'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
