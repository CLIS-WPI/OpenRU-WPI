# Incident: GPU chain smoke run wedged the allowed H100

Status: **GPU work stopped.** No reset, no driver reload, no further GPU commands.
Read-only diagnosis only; the hung processes were left untouched.

## Summary

| item | value |
|---|---|
| When | 2026-11-20 19:55:44 UTC (process start); Xid 13 at 19:55:46; Xid 31 at 19:56:16 |
| Process | `test_chain`, PID 3474074 |
| GPU | index **1** (device minor 1), PCI **0000:44:00.0**, UUID `GPU-509d8ab3-0c8e-8b98-fbf8-0c55f6ba9058` |
| Other GPU | index 0, PCI `0000:43:00.0`, UUID `GPU-96b18ccc-...`; **not in use** (no `/dev/nvidia*` fds) |
| Failure | Xid 13 (Graphics Exception) then Xid 31 (MMU Fault, `FAULT_PDE ACCESS_TYPE_VIRT_WRITE`) |
| Result | smoke run produced no stdout rows; `/tmp/chain_smoke.csv` is 0 bytes |

## Kernel log (NVRM/Xid since the hang)

```
Nov 20 19:55:46 GPU-server kernel: NVRM: GPU at PCI:0000:44:00: GPU-509d8ab3-0c8e-8b98-fbf8-0c55f6ba9058
Nov 20 19:55:46 GPU-server kernel: NVRM: GPU Board Serial Number: 1650724003118
Nov 20 19:55:46 GPU-server kernel: NVRM: Xid (PCI:0000:44:00): 13, pid=3474074, name=test_chain, Graphics Exception: channel 0x0000000c, Class 0000cbc0, Offset 00000510, Data 0017e2ac
Nov 20 19:56:16 GPU-server kernel: NVRM: Xid (PCI:0000:44:00): 31, pid=3474074, name=test_chain, channel 0x0000000c, intr 00000000. MMU Fault: ENGINE GRAPHICS GPC0 GPCCLIENT_T1_0 faulted @ 0x7f56_b7c1f000. Fault is of type FAULT_PDE ACCESS_TYPE_VIRT_WRITE
```

After the Xid 31 there are only `nvidia-*rm` stack traces and "task nvidia-smi blocked
for more than ... seconds" messages; no additional Xid codes.

## Exact smoke command

Run from `~/deepseek-wt/gpu-chain` (worktree branch `bench/gpu-chain`, base
`bbec043`), binary `build/cm-avx2/test_chain` built from the uncommitted
`tests/test_chain.cpp` + CMake target:

```
CUDA_VISIBLE_DEVICES=GPU-509d8ab3-0c8e-8b98-fbf8-0c55f6ba9058 \
  taskset -c 8 ./build/cm-avx2/test_chain --iters 3 --cpu-core 8 \
  --csv /tmp/chain_smoke.csv
```

The harness loops profiles `20/40/100 MHz` and ports `2/4/8`, in that order. The
first configuration is 20 MHz / 2 ports; the fault happened ~2 s after start, so
the first configuration is the one that faulted. No row was written.

### First-configuration sizes (20 MHz, 2 ports, layers=2)

- DFT 768, 51 RB, 612 RE, slot 11520 samples, `prb_size=28` bytes.
- Compressed layer grid (single H2D): `2*14*51*28 = 39,984` bytes.
- Decompressed layer cbf16: `2*14*612*2 = 34,272` bytes.
- Port grid cbf16: `2*14*612*2 = 34,272` bytes.
- Time-domain ci16 output (single D2H): `2*11520*2 = 46,080` bytes.
- Cat-B weights: `51*2*2*8 = 1,632` bytes (preloaded before timing).

The full matrix would allocate larger buffers for 40/100 MHz and 4/8 ports, but
the failure occurred in the first configuration.

## Other GPU usage

`/proc/driver/nvidia/gpus/*/information` reports:

- `0000:43:00.0` (GPU 0, `GPU-96b18ccc-...`) — no `/dev/nvidia*` file descriptors
  from any process; not in use.
- `0000:44:00.0` (GPU 1, `GPU-509d8ab3-...`) — this incident.

A read-only `/proc/*/fd` scan found only a hung `nvidia-smi` holding
`/dev/nvidiactl`; no other compute process had an NVIDIA device open. The
`test_chain` process no longer exposes fds but is still present.

## Current processes (left untouched)

- `3474074 test_chain` — `R` (spinning after the fault; no longer producing GPU
  work from our side, but not stopped/killed by us after the diagnosis).
- `3474088 nvidia-smi` — `D` (blocked in the driver).
- `3513870 nvidia-smi` — `Tl` (stopped; from the diagnostic query).

No GPU reset, driver reload, or process signal was issued after the failure.

## Likely cause (to be confirmed)

Xid 31 reports an MMU PDE fault with `ACCESS_TYPE_VIRT_WRITE`, i.e. the GPU tried
to write through an invalid/unmapped virtual address. That points to an
out-of-bounds device write in the chain harness rather than a hardware fault.
Candidates, in order:

1. `lowphy_catb_precode` input/output sizing or weight layout for the chain
   (`layers` vs `ports`, per-PRB weights), or
2. `lowphy_bfp_decompress` input layout for the compressed layer grid, or
3. OFDM plan/buffer dimensions (`ports` × 14 × 612 input, `ports` × 11520 output).

The existing per-stage cost-model and pipeline tests do not exercise this exact
decompress→precode→OFDM buffer combination, so it is not covered by their
current checks. No conclusion is claimed until compute-sanitizer runs.

## Required recovery and next step (after human recovery)

1. Human recovers the host/GPU (reset or reboot); do not reset from this agent.
2. Add a smallest-case selector to `test_chain` (20 MHz, 2 ports, 1 slot,
   `--iters 1`) and run under compute-sanitizer with a hard timeout around every
   invocation, e.g.:

   ```
   timeout 300 compute-sanitizer --tool memcheck --error-exitcode 99 \
     ./build/cm-avx2/test_chain --profile 20 --ports 2 --iters 1 --cpu-core <reserved>
   timeout 300 compute-sanitizer --tool racecheck --error-exitcode 99 \
     ./build/cm-avx2/test_chain --profile 20 --ports 2 --iters 1 --cpu-core <reserved>
   ```

3. Only after the smallest case is clean, proceed to the single-chain PR A
   measurement (one H2D, one D2H, goldens, p50/p99, reserved-core/GPU-exclusive
   gates, clocks), then PR B/C.

No benchmark number is reported in this note.
