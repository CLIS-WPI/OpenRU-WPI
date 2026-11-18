# CPU / GPU topology — this lab host

Date: 2026-11-13 \[MEASURED]

## Summary

| Fact | Value |
| --- | --- |
| CPU | AMD EPYC 9354 32-Core × 2 sockets |
| SMT | **off** (`Thread(s) per core: 1`) |
| NUMA | node0 = CPUs 0–31; node1 = CPUs 32–63 |
| GPU0 PCI | `0000:41:00.0` → **numa=0**, local_cpulist=0–31 |
| GPU1 PCI | `0000:44:00.0` → **numa=0**, local_cpulist=0–31 |
| `nvidia-smi topo` | Both GPUs: CPU Affinity 0–31, NUMA Affinity 0; NV12 between GPUs |

`thread_siblings_list` for cpus 0, 16, 32, 48 is a **singleton** (e.g. `cpu32: 32`).  
**32–63 are not SMT siblings of 0–31** — they are the second socket / NUMA1.

## Pinning decision

SMT clause did **not** require a re-pin (32–63 are not siblings of 0–31).

Optional NUMA0 co-location with GPU1 was measured and **rejected for OFH**:

| Pin | 600 s late/(rx+tx) | late sum | drop |
| --- | --- | --- | --- |
| NUMA1 `32-47` / `48-55` (prior) | **~4.9e-6** | 72 | 0 |
| NUMA0 `16-27` / `28-31` (trial) | **~6.6e-5** | 977 | 0 |

**Final pin** (in `docker/lab.env.example`): `PROTORU_CPUSET=32-47`, `DU_CPUSET=48-55`, yaml `timing_cpus: [32]`, `ofh_cpus: [33, 34]`. Revisit for CUDA H2D in M2 if needed.

## Raw probes

### `lscpu -e` (excerpt)

See host: cores 0–31 → NODE 0 SOCKET 0; cores 32–63 → NODE 1 SOCKET 1.

### Siblings

```
cpu0: 0
cpu16: 16
cpu31: 31
cpu32: 32
cpu48: 48
```

### `nvidia-smi topo -m`

```
        GPU0    GPU1    CPU Affinity    NUMA Affinity   GPU NUMA ID
GPU0     X      NV12    0-31            0               N/A
GPU1    NV12     X      0-31            0               N/A
```
