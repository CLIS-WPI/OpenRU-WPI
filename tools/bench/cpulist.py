#!/usr/bin/env python3
"""Parse CPU lists as they appear in sysfs/lscpu/kernel cmdlines.

Accepted forms (mixed freely, with commas, spaces, newlines or a mix):
    "2-5,8"      "0 1 2"      "0-11,12-19"      "managed_irq,2-11" (domains ignored by the caller)
    "0 1 10 11 2-3"          ""  (empty)

The parser returns sorted unique CPU numbers and rejects malformed tokens so a
crash like int('0 1 10 11 2 3 ...') cannot happen again.
"""
import argparse
import pathlib
import sys


def parse(text: str) -> list[int]:
    cpus: set[int] = set()
    tokens = [t for t in text.replace(",", " ").split() if t]
    for tok in tokens:
        if "-" in tok:
            parts = tok.split("-")
            if len(parts) != 2 or not parts[0].isdigit() or not parts[1].isdigit():
                raise ValueError(f"bad range token {tok!r}")
            lo, hi = int(parts[0]), int(parts[1])
            if hi < lo:
                raise ValueError(f"reversed range {tok!r}")
            cpus.update(range(lo, hi + 1))
        else:
            if not tok.isdigit():
                raise ValueError(f"bad CPU token {tok!r}")
            cpus.add(int(tok))
    return sorted(cpus)


def _normalize(text: str) -> str:
    cpus = parse(text)
    out: list[str] = []
    i = 0
    while i < len(cpus):
        j = i
        while j + 1 < len(cpus) and cpus[j + 1] == cpus[j] + 1:
            j += 1
        out.append(str(cpus[i]) if i == j else f"{cpus[i]}-{cpus[j]}")
        i = j + 1
    return ",".join(out)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", choices=["expand", "normalize", "check", "contains", "hybrid"])
    ap.add_argument("lists", nargs="*")
    ap.add_argument("--core-file", default="/sys/devices/cpu_core/cpus")
    ap.add_argument("--atom-file", default="/sys/devices/cpu_atom/cpus")
    ap.add_argument("--which", choices=["p", "e"], default="p")
    args = ap.parse_args()
    try:
        if args.command == "expand":
            print(" ".join(str(c) for c in parse(args.lists[0])))
        elif args.command == "normalize":
            print(_normalize(args.lists[0]))
        elif args.command == "check":  # every CPU of list 1 is in list 2
            sub, sup = (set(parse(t)) for t in args.lists[:2])
            missing = sorted(sub - sup)
            if missing:
                print("missing: " + " ".join(map(str, missing)), file=sys.stderr)
                return 1
        elif args.command == "contains":  # CPU is in list
            sys.exit(0 if int(args.lists[0]) in set(parse(args.lists[1])) else 1)
        elif args.command == "hybrid":  # P/E from the hybrid-capable sysfs lists
            path = pathlib.Path(args.core_file if args.which == "p" else args.atom_file)
            print(" ".join(str(c) for c in parse(path.read_text())) if path.is_file() else "")
    except ValueError as exc:
        print(f"cpulist: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
