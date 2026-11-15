# AGENTS.md — OpenRU Phase 1

## Repo facts

- The git repo is `openru-sw/`, not the parent directory. Run all git/make commands here.
- `external/proto-ru` is a git submodule: the OpenRU fork of ProtO-RU (branch `openru/main`). Radio/low-PHY/CUDA changes belong here, not copied into `openru-sw/`.
- `docs/BRIEF_PHASE1.md` is the authoritative milestone spec. Work M0 → M5 in order; do not start the next milestone until the prior acceptance gate passes.

## Commands

```bash
cd openru-sw
cp docker/lab.env.example docker/lab.env   # edit GPU UUID/cpusets; file is gitignored
make preflight                             # fails closed if lab.env is missing/GPU absent
make build                                 # core + ProtO-RU/OCUDU image (long)
make smoke-fh                              # M0 emulator 60 s gate (SMOKE_SECS=...)
make smoke-fh PROTORU_PROFILE=null         # M1 null-radio path
make smoke-core                            # NG Setup against Open5GS
make capture PROFILE=baseline CAPTURE_SECS=10
make gpu-check && make down
```

- The build service is `ocudu` (compose profile `build`), not `du`/`protoru`; `du` and `protoru` share the `openru/protoru` image. `docker compose build du` builds nothing—use `make build-protoru`.
- The Dockerfile default is `EXTRA_CMAKE_ARGS=-DOPENRU_CUDA=OFF`, and compose does not forward that arg. M2 must wire a CUDA build arg through compose before expecting kernels.
- There is no unit-test suite in `openru-sw`. Verification is via make targets plus `tools/`:
  - `python3 tools/iq_compare/iq_compare.py --dut DIR --golden DIR --by-slot --threshold 0`
  - `scripts/determinism_check.sh DIR_A DIR_B`
  - `python3 tools/fh_replay/fh_replay.py --pcap ... --iface ... --dst-mac ... --src-mac ... --rate 1.0`
- Python tools use the active `python3`; install `numpy` and (for replay) `scapy`—there is no requirements file/venv.
- `make capture` needs `sudo tcpdump` on the host bridge; it falls back to tcpdump inside the `protoru` container.

## Gates and measurement rules

- `smoke-fh` gate: after warm-up, fail if `drop > 0` or `late/(rx+tx) >= 1e-5`. Canonical CPU baseline is ratio `2.096e-6` (600 s, warm-up 57 s). M2 CUDA must not regress past that.
- `smoke-fh` exits 0 on pass and non-zero on fail. There is no soft-fail state; exit code 2
  is removed. A failure blocks the milestone until explained in the report.
- Never present compute-only timings as fronthaul delay profiles. Reports (`docs/reports/M<n>.md`) tag every number `[MEASURED]`, `[DATASHEET]`, `[DERIVED]`, `[ASSUMPTION]`, or `[UNVERIFIED]`, and end with an `Unverified` list.
- No fabrication: do not patch tests/logs to go green; record failures. Human-only decisions go in `docs/OPEN_QUESTIONS.md`, continue on the stated default.

## GPU / host constraints

- Use only the GPU UUID in `docker/lab.env` (GPU 1). Never `--gpus all`, never GPU 0, and never `privileged: true` on `protoru`—privileged breaks the device pin.
- Keep the measured CPU pins: `PROTORU_CPUSET=32-47`, `DU_CPUSET=48-55` (NUMA1). A NUMA0 trial measurably worsened OFH late ratio; do not "improve" pinning without a 600 s run.
- Host is Ubuntu 22.04.5, containers 24.04, no PREEMPT_RT, no PTP. GPU pin/cpuset values are host-specific and gitignored.

## Radio / profile gotchas

- Emulator mode (no `sdr:` block, `profiles/baseline/protoru.yml`) is M0-only: it does not run low-PHY or produce golden IQ. M1 uses `protoru-null.yml` with `sdr.device_driver: null`, `tx_dump=/dev/shm/...`, `pace=realtime`.
- Null radio advances its clock only in `receive()`; `pace=free` is throughput-only and must be labeled as such. Dumps are per-port `portN.cf32` plus `iq_meta.json` and `tx_index.jsonl`.
- Compose chooses configs via `DU_CONFIG_PATH` / `PROTORU_CONFIG_PATH`. Add a new `profiles/<name>/` for new work; never edit `profiles/baseline/`.
- `baseline` is 20 MHz 2x2 (frozen, M0 reference). `b40` (40 MHz 2x2) and `b100`
  (100 MHz 2x2) are added in M1 with their own CPU golden and late-ratio baseline.
  M2's acceptance gate uses `b40`; `b100` is reported. `b20` is removed as a duplicate.
- ProtO-RU needs the enlarged T1a/Ta4 (≤5000 µs) delay profile; see `external/proto-ru/proto-ru/INTEGRATION_NOTES.md`.

## Builds and images

- NUM_JOBS is passed through compose as a build arg (build.args: NUM_JOBS: ${NUM_JOBS:-32}).
  Default is 32 on this shared server; the build log must show -j32. Never use -j$(nproc).
- Image tags are per milestone and commit: openru/protoru:<milestone>-<short-sha> plus a moving
  openru/protoru:<milestone> (e.g. m1). Set OPENRU_TAG accordingly. Never retag or overwrite an
  earlier milestone's image.
- Dockerfile layer order: dependency scripts and UHD/DPDK before the ProtO-RU source ADD;
  OCUDU build uses ccache with a BuildKit cache mount. A change in external/proto-ru must not
  rebuild UHD or DPDK; if it does, that is a bug to fix before continuing.

## Long-running commands

- Any command that can run longer than 2 minutes (builds, smoke runs, captures) is started in
  the background, wrapped in `timeout`, with output to a log file, e.g.
  `timeout 1800 make build-protoru > logs/build.log 2>&1 &`; poll the log every 60 s and report
  progress. Never run such a command in the foreground without a timeout.
- Never call `sudo` interactively. If a step needs root and passwordless sudo is not configured,
  use the in-container fallback or stop and ask the human.

## Multiple agents

- Agent-instruction files (AGENTS.md, CLAUDE.md, .cursorrules, etc.) are edited only by the
  human or in a PR the human approves. Agents propose changes in PR descriptions.
- Secondary agents work in a separate `git worktree` on their own `ds/<task>` branch and never
  commit to `main` or a milestone branch.
- Any run that measures latency or late/drop ratio creates /tmp/openru-measure.lock for its
  duration and removes it after (use a trap so it is removed on failure too). While the lock
  exists, no agent runs docker builds, compose, GPU 1 work, or anything on cores 32-63.
  Never start a measurement while a docker build is running.
- Never `git add -A` or `git add .`; stage files explicitly.

## Licensing / upstreaming / branching

- Anything linked to or derived from ProtO-RU stays AGPLv3. Keep `src/mpd/` and `tools/` free of ProtO-RU code so they can remain BSD-3.
- The repository LICENSE is AGPL-3.0. Directories intended as BSD-3
  (src/mpd/, tools/) carry their own LICENSE file; until they do, they are AGPL-3.0.
- Upstreamable ProtO-RU changes go in the submodule fork on a feature branch (`feat/null-radio`, ...). Docker builds use the checked-out submodule contents; commit in the fork and bump `PROTORU_GIT_COMMIT` in `docker/versions.env` for reproducibility.
- `main` must stay green; one branch per milestone (`m1-harness`, `m2-cuda`, ...).
