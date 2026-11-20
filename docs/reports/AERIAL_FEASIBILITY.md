# Aerial cuPHY test-bench feasibility (read-only)

Date: 2026-11-20. Scope: can NVIDIA Aerial CUDA-Accelerated RAN's cuPHY test
benches run on this host? Nothing was installed, downloaded, or executed.

## Verdict

**Not supported as-is.** The cuPHY GPU-only test benches (`cubb_gpu_test_bench`)
do not need a NIC, so the missing ConnectX card is not the blocker. The blockers
are the software baseline and platform qualification:

- Aerial's current release (26-2) manifest requires CUDA **13.3** with driver
  **610.57.04** and CUDA toolkit **13.3**. This host has driver **580.126.09**
  (driver API CUDA 13.0) and `nvcc` **12.5** (V12.5.40).
- Aerial's supported gNB systems are MGX ARC Pro, Grace Hopper MGX, and DGX Spark.
  The x86 platform is supported only as an **RU emulator** (Dell R750, Xeon Gold
  6336Y). This host is a dual EPYC 9354 x86 server with H100 NVL GPUs, which is
  not a qualified gNB or RU-emulator configuration. (BlueField-3 appears in the
  manifest as a NIC/FW item for Grace Hopper/MGX, not as the x86 RU-emulator
  qualifier.)
- Even the GPU-only benches are built from the same SDK and are gated on the
  manifest versions; running them on a below-manifest toolkit/driver is
  unsupported and not a result we could cite.

For a full cuBB end-to-end run the host would additionally need a supported
ConnectX NIC, a PTP-capable NIC clock, hugepages, and DPDK — none of which are
present (see below).

## Host evidence

| Item | This host | Aerial 26-2 requirement |
|---|---|---|
| GPU | 2× NVIDIA H100 NVL, CC 9.0, 95830 MiB | Supported list is platform-based; H100 NVL x86 is not listed |
| Driver | 580.126.09 | 610.57.04 |
| CUDA driver API | 13.0 | 13.3 |
| CUDA toolkit (`nvcc`) | 12.5 (V12.5.40) | 13.3 |
| NIC | Intel X710 10GbE, Intel I350 1GbE | ConnectX; BF3 is listed for GH/MGX, not the x86 RU-emulator qualifier |
| RDMA | no `ibv_devinfo`, no Mellanox devices | required for cuBB |
| PTP | `/dev/ptp0..3` from `i40e`/`igb`; no `ptp4l`/`phc2sys` | NIC PTP + `ptp4l`/`phc2sys` |
| Hugepages | 0 | required for cuBB |
| DPDK | no `dpdk-devbind.py` | required for cuBB |

## What could run in principle

- `testBenches/cubb_gpu_test_bench` is described as a GPU-only bench; the NIC is
  needed only for the cuBB end-to-end path. On a *supported* platform with the
  right toolkit/driver it would not need the ConnectX card.
- The repository provides `minimal-x86` and `minimal-arm` CMake presets and an
  `x86-64` toolchain under `cuPHY/cmake/toolchains/`, so an x86 build is
  mechanically possible.

## What would have to change (out of scope here)

1. Driver ≥ 610.57.04 and CUDA toolkit 13.3 (or whatever the chosen
   release's manifest pins).
2. A supported platform, or explicit acceptance that results are unqualified.
3. For cuBB (not just cuPHY benches): a supported ConnectX NIC, PTP setup,
   hugepages, and DPDK.

## Sources

- Aerial docs: https://docs.nvidia.com/aerial/cuda-accelerated-ran/latest/index.html
- Software manifest: https://docs.nvidia.com/aerial/cuda-accelerated-ran/latest/install_guide/software_manifest.html
- cuPHY SDK quickstart: https://docs.nvidia.com/aerial/cuda-accelerated-ran/latest/quickstart_guide/running_cuphy_sdk.html
- DGX Spark install notes: https://docs.nvidia.com/aerial/cuda-accelerated-ran/latest/install_guide/installing_tools_spark.html
- Repository: https://github.com/NVIDIA/aerial-cuda-accelerated-ran
- Pinned source files (commit `4f65f97c`):
  - https://github.com/NVIDIA/aerial-cuda-accelerated-ran/blob/4f65f97c1d5f701ce911f7dda8f1b1f3f0c7693c/CMakePresets.json
  - https://github.com/NVIDIA/aerial-cuda-accelerated-ran/blob/4f65f97c1d5f701ce911f7dda8f1b1f3f0c7693c/testBenches/README.md
  - https://github.com/NVIDIA/aerial-cuda-accelerated-ran/blob/4f65f97c1d5f701ce911f7dda8f1b1f3f0c7693c/testBenches/CMakeLists.txt
  - https://github.com/NVIDIA/aerial-cuda-accelerated-ran/blob/4f65f97c1d5f701ce911f7dda8f1b1f3f0c7693c/aerial-sdk-version
  - https://github.com/NVIDIA/aerial-cuda-accelerated-ran/tree/4f65f97c1d5f701ce911f7dda8f1b1f3f0c7693c/cuPHY/cmake/toolchains/x86-64
  - https://github.com/NVIDIA/aerial-cuda-accelerated-ran/blob/4f65f97c1d5f701ce911f7dda8f1b1f3f0c7693c/cuPHY/CMakeLists.txt

Note: the release PDF in the docs tree is labeled Release 26.1.0 (Jun 15 2026),
while the docs site serves release 26-2. The manifest requirements above are
from the 26-2 docs.
