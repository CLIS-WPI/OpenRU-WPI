# STOP — M1 null smoke-fh not reproducible at 7.094e-6 (host changed)

Date: 2026-11-14. Image: `openru/protoru:m1` (`5d2846ec7fad`), `PROTORU_PROFILE=null`, 600 s.
Same pin policy: `PROTORU_CPUSET=32-47`, `DU_CPUSET=48-55`, GPU1 only.
**Do not start the FFTW×MARCH 2×2 or `max_proc_delay` sweep until pins are clear.**

## Baseline vs today [MEASURED]

| Run | Gate late_frac | late | drop | all_pkts | vs M1 ref 7.094e-6 |
|---|---:|---:|---:|---:|---|
| M1 reference (historical) | **7.094e-6** | 104 | 0 | 14,660,806 | — |
| Today r1 | **2.215e-5** | 326 | 0 | 14,720,660 | **~3.1× worse** |
| Today r2 | **2.609e-5** | 384 | 0 | 14,720,770 | **~3.7× worse** |

Neither run is “~7e-6”. Gate warm-up classifier: `lates not start-clustered; warm-up=0` on both (lates spread through the run).

## Late by direction / plane [MEASURED]

| Run | DL U-plane | DL C-plane | UL C-plane @RU | PRACH |
|---|---:|---:|---:|---|
| r1 | 268 | 10 | 48 | not broken out in `parse_smoke_fh` |
| r2 | 348 | 10 | 26 | same |

DU side: r1 `ul_rx_late=189` / past-seq drops 1392; r2 `ul_rx_late=171` / past-seq 871. No DU TX late KPIs.

## Late time distribution [MEASURED]

- **r1:** 30 nonzero 1 s bins; late_sum by minute `{0:136, 1:59, 2:49, 3:4, 7:17, 8:29, 9:4, 10:28}` — bursts around t≈0, 98–126 s, 420 s, 539–604 s.
- **r2:** 13 nonzero bins; by minute `{0:110, 1:28, 5:131, 6:2, 7:5, 8:20, 9:88}` — large cluster ~329–333 s and spike at t+597 s.

Artifacts: `r1-kpi.json`, `r2-kpi.json`, `r*-late-hist.csv`, `logs/m1-baseline-r*.log`.

## Host load during runs [MEASURED]

Other containers up the whole time: `paperbanana-api`, `ollama`, `ngsi-dev-1`, `harmony-dev-proxy`, `minikube`.

**Pin contention on the OpenRU cpusets (root cause of non-reproducibility):**

| Core | Process | ~%CPU | Overlaps |
|---|---|---:|---|
| 46 / 37 | `nr-uesoftmodem` (OAI UE rfsim) | **~129** | `PROTORU_CPUSET=32-47` |
| 50 | `nr-softmodem` (OAI gNB rfsim) | **~168** | `DU_CPUSET=48-55` |
| 55 | `nr-uesoftmodem` | **~54** | `DU_CPUSET=48-55` |

Host sampler: `logs/hostload/m1-r1-host.csv`, `m1-r2-host.csv`.  
r1 avg load1 rose ~6.4 → ~12–13 during the run; r2 avg load1 ≈ **11.7**.  
GPU0 util 0% (841 MiB held); GPU1 util 0% (OpenRU lane idle aside from our containers).

## ProtO-RU per-thread CPU (mid-run samples) [MEASURED]

r1 (`r1-mid-cpu.txt`): `ru_timing` ~49%, `ru_rx`/`ru_emu`/`ru_ofh_tx`/`ru_phy_*` ~36–45% on cores 32–47.  
r2 (`r2-mid-cpu.txt`): similar; DU `gnb` threads on 49–55 with `ru_timing`/`ru_txrx` ~60% **sharing cores with OAI softmodems**.

## FFTW code notes (for when isolation resumes) [DATASHEET from source]

- Plans created in `dft_processor_fftw_impl.cpp:142` via `fftwf_plan_dft_1d(...)`.
- Flags (`dft_processor_fftw_impl.h:19–25`): `FFTW_ESTIMATE`, `FFTW_MEASURE`, `FFTW_EXHAUSTIVE` — **no `FFTW_PATIENT`**.
- Lower PHY uses `create_dft_processor_factory_fftw_fast()` → **`measure`**, timeout **5.0 s** (`generic_functions_factories.h:68–76`).
- Upper PHY uses `fftw_slow` → **`estimate`**, timeout **1.0 s** (`:58–60`).
- Construction sites call `dft_factory->create(...)` when factories build processors (e.g. `modulation_factories.cpp:31,55–56` pool pre-creates `max_nof_threads` modulators at lower-PHY setup; transform precoder builds all valid PRB sizes in `transform_precoding_factories.cpp:28–36` at `create()`). That is **startup / factory time**, under `mutex_init`, not the steady-state RT tick — but it is **not** hard-guaranteed to be off the ofh/phy worker threads if a late factory `create()` runs there. No evidence of re-planning on every symbol.

M1 image already links `libfftw3f` and CMake “Found FFTW3F” at build (`logs/build-m1-gate.log`); MARCH was **x86-64-v3**. M2 image added explicit `-DENABLE_FFTW=ON` + **x86-64-v4**. Isolation of FFTW vs v4 still requires a quiet host.

## Decision

**STOP.** Host changed (OAI rfsim softmodems on OpenRU pins). Cannot attribute M2’s 4.5e-5 regression to FFTW/v4 until M1 again reproduces ~7e-6 on a quiet NUMA1 pin set. Next human action: move or stop OAI `nr-softmodem` / `nr-uesoftmodem` off cores **32–55**, then re-run the two M1 baselines.
