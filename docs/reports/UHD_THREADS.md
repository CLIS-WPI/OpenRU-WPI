# UHD data path and threads (N310, UHD 4.11, ProtO-RU)

Read-only source study, 2026-11-20, of ProtO-RU at the `external/proto-ru` submodule commit and UHD v4.11.0.0; load
figures from the Phase D 60-minute 2T2R run (docs/SPLIT_DU.md). Nothing here was measured on RF beyond that run; the
measurement for the next RF session is `scripts/uhd_threads_probe.sh` (not yet run).

Path conventions: `P:` = `openru-sw/external/proto-ru/` (ProtO-RU submodule), `R:` = `openru-sw/`,
`U:` = UHD tag `v4.11.0.0`, path `host/...`. Tags: [source] = read in code at file:line,
[measured] = Phase D 60-min 2T2R run (facts supplied), [inferred] = reasoning, not verified.

## Summary

- **No UHD thread carries IQ samples.** With these device args UHD uses the *inline* I/O service for both
  data directions, so every sample is moved by ProtO-RU's own threads inside `send()`/`recv()` [source].
- **TX samples: `ru_phy_tx_#0`** (calls `tx_streamer::send`). **RX samples: `ru_phy_rx_#0`** (calls
  `rx_streamer::recv`). `ru_phy_ul_#0` only processes RX buffers after the fact; `ru_radio_#0` only polls async
  messages [source]. The prior belief (TX via ru_phy_tx) is **confirmed**, and RX is the mirror image.
- UHD creates: `uhd_ctrl_ep0001` (control/async-message receiver, busy-polls), `action_handler`, `uhd_log`, and two
  threads whose names are too long for Linux and so show up as `ru_emulator` (`mpmd_claimer_task`,
  `uhd_log_fp_dummy`). The gRPC threads (`event_engine`, `default-executor`, `timer_manager`, ...) come from
  **UHD's gRPC MPM client**, not from ProtO-RU [source].
- All of them are SCHED_RR 89 because ProtO-RU sets RR 0.90 on the init thread before creating the USRP, and
  every thread created after that inherits it [source]. `uhd_ctrl_ep0001` loops on non-blocking recv,
  poll(0) and a 1 ns sleep. As an RT task it gets no timer slack, so it uses 100% of a CPU. No device arg
  changes that [source+inferred].
- Each sample is copied **twice by the CPU in each direction**: one kernel copy in the socket call
  and one `memcpy` (the sc16->sc16 "conversion"). There are no ProtO-RU-side copies [source].
- Syscalls to trace: `sendto`, `recvfrom`, `poll`, `clock_nanosleep` (libc `send`/`recv` map to
  sendto/recvfrom on x86_64) [source+inferred].

## Sample path

Thread creation [source]: `P:apps/examples/ofh/ru_emulator.cpp:688-692` (`ru_radio`, `no_realtime()`),
`:713-717` (`ru_phy_hp`, max()-2), triple profile `:746-768` (`ru_phy_tx` max(), `ru_phy_rx` max()-2,
`ru_phy_ul` max()-1). `execution_profile: auto` resolves to triple when there are 8 or more CPUs
(`ru_emulator.cpp:636-640`). Mapping
in `P:lib/ru/sdr/ru_sdr_executor_mapper.cpp:101-120`: dl/prach -> hp, ul -> ul_exec, tx -> tx_exec,
rx -> rx_exec, async -> radio. Lower PHY wiring `P:lib/phy/lower/lower_phy_factory.cpp:145-149`
(transmitter/receiver = UHD baseband gateway, `P:lib/radio/uhd/radio_uhd_baseband_gateway.h:31-34`).

### TX (DL), all on `ru_phy_tx_#0` [source]
1. `lower_phy_baseband_processor::dl_process` runs on `tx_executor` (`P:lib/phy/lower/lower_phy_baseband_processor.cpp:58,134-136`).
   It first spin-sleeps in 10 us steps until RX time catches up (`:89-92`, `sleep_for(10us)`). Then it builds the
   buffer (`:115-116`) and calls `transmitter.transmit(...)` (`:126`).
2. `radio_uhd_tx_stream::transmit` -> `transmit_block` -> `stream->send(buffs, n, md, 0.001 s)`
   (`P:lib/radio/uhd/radio_uhd_tx_stream.cpp:182-308`, send at `:115`). `cpu_format="sc16"` (`:136`).
   otw = sc16 because the profile sets none (DEFAULT -> sc16; SC12 is forced only for B2xx, `P:lib/radio/uhd/radio_uhd_impl.cpp:297-302`).
   The buffers are `ci16_t` (`P:include/ocudu/gateways/baseband/buffer/baseband_gateway_buffer_dynamic.h:35`), and the pointer is passed straight through.
3. UHD: `tx_streamer_impl::send` -> `_send_one_packet` (`U:host/lib/include/uhdlib/transport/tx_streamer_impl.hpp:209,472-496`):
   get a frame buffer, `_converters[i]->conv(...)` (`:490`), `release_send_buff` (`:492`).
4. Flow control is inline: `chdr_tx_data_xport::get_send_buff` -> `wait_for_dest_ready`
   (`U:host/lib/include/uhdlib/rfnoc/chdr_tx_data_xport.hpp:235-238`) -> `inline_io_service` polls the TX link's
   receive side for stream-status packets (`U:host/lib/transport/inline_io_service.cpp:274-291,495-524`).
   Stream status / EOB-ACK / seq-error async events are queued **from this same thread** (`chdr_tx_data_xport.hpp:367-380`,
   `U:host/lib/rfnoc/rfnoc_tx_streamer.cpp:155-166`).
5. Release -> `_send_cb` -> `udp_boost_asio_link::release_send_buff_derived` -> `send_udp_packet` -> `::send(fd, mem, len, 0)`
   (`U:host/lib/include/uhdlib/transport/udp_boost_asio_link.hpp:138-140`, `udp_common.hpp:128-148`. On ENOBUFS it
   retries with a 1 us sleep, `:138-141`).

### RX (UL), on `ru_phy_rx_#0`, then hand-off to `ru_phy_ul_#0` [source]
1. `ul_process` on `rx_executor` pops a free buffer and calls `receiver.receive(...)` (`lower_phy_baseband_processor.cpp:147,151`).
2. `radio_uhd_rx_stream::receive` loops `receive_block` -> `stream->recv(buffs, n, md, 0.2 s, one_packet=false)`
   (`P:lib/radio/uhd/radio_uhd_rx_stream.cpp:95-169`, recv at `:34`, cpu/otw sc16 at `:47-51`).
3. UHD: `rx_streamer_impl::recv` -> `_recv_one_packet` -> `get_recv_buffs` -> `conv(...)` into the user buffer
   (`U:host/lib/include/uhdlib/transport/rx_streamer_impl.hpp:184,325-365,410`). The xport receive goes through
   `chdr_rx_data_xport::get_recv_buff` (`U:host/lib/include/uhdlib/rfnoc/chdr_rx_data_xport.hpp:263-266`) ->
   `inline_io_service::recv` (`inline_io_service.cpp:462-493`) -> `recv_udp_packet` (`udp_common.hpp:101-126`).
   Flow-control responses go back out on the same thread (`chdr_rx_data_xport.hpp:334-337,378-380,388`).
4. The filled buffer is moved by pointer to `uplink_executor` = `ru_phy_ul_#0` (`lower_phy_baseband_processor.cpp:158-165`).
   No copy is made.

### Why there is no offload thread [source]
`io_service_mgr_impl::connect_links` (`U:host/lib/usrp/common/io_service_mgr.cpp:469-551`): CTRL links always use INLINE
(`:503-504`). Data links use offload only if `recv_offload`/`send_offload` is set (`:506-520`). MPMD defaults are both
`false` (`U:host/lib/usrp/mpmd/mpmd_mb_iface.cpp:25-32`, passed at `:322-327` RX and `:407-410` TX). The args are read
from device args + stream args (`U:host/lib/usrp/common/io_service_args.cpp:61-64`). The bench device args
(`R:profiles/bench-split-20mhz-2t2r/protoru.yml:68`: `type=n3xx,addr=<N310 address>,mgmt_addr=<N310 address>,
clock_source=internal,time_source=internal,master_clock_rate=122.88e6`) set none of these, and ProtO-RU passes empty
stream args. DPDK is not used either: there is no `use_dpdk` (`io_service_mgr.cpp:451-466`), so the link is
`udp_boost_asio_link` (`U:host/lib/usrp/mpmd/mpmd_link_if_ctrl_udp.cpp:461-465`). The measurement agrees: no offload thread was seen [measured].

## Async/control path (not samples, but timing-relevant) [source]
FPGA radio async msgs (TX underrun / late, RX overrun) arrive as CHDR control packets on the control link ->
`uhd_ctrl_ep0001` -> `ctrlport_endpoint::handle_recv` -> `radio_control_impl::async_message_handler`
(`U:host/lib/rfnoc/radio_control_impl.cpp:1251-1350`) -> `post_action(..., ASYNC)` -> `action_handler` thread ->
`rfnoc_tx_streamer::_handle_tx_event_action` -> lock-free queue (`rfnoc_tx_streamer.cpp:312-327`) / RX overrun
handling (`U:host/lib/rfnoc/rfnoc_rx_streamer.cpp:179-185,305-330`). `ru_radio_#0` polls that queue:
`recv_async_msg(…, 1 ms)` (`P:lib/radio/uhd/radio_uhd_tx_stream.cpp:12,24`) -> UHD checks it every 100 us with
`sleep_for` (`U:host/lib/rfnoc/tx_async_msg_queue.cpp:16-43`), then re-defers itself (`radio_uhd_tx_stream.cpp:77-90`).
This explains the 1% load [measured].

## Threads table

Sched "as set": UHD itself sets no priority on any thread it creates. ProtO-RU calls `uhd_set_thread_priority(0.90, true)`
before `usrp_make` (`P:lib/radio/uhd/radio_uhd_impl.cpp:189-192`). That becomes SCHED_RR with prio int(0.9*98)+1 = **89**
(`U:host/lib/utils/thread.cpp:47-69`). Every thread created by that init thread inherits it. The init thread is restored
to OTHER only at the end (`radio_uhd_impl.cpp:480`) [source]. Names are set with `pthread_setname_np(name.substr(0,16))`
(`U:host/lib/utils/thread.cpp:181-185`). The kernel limit is 15 chars + NUL, so names of 16 or more chars fail with
ERANGE and the thread keeps the process comm `ru_emulator` [source+inferred].

| name (comm) | created by | role | sched as set | busy-poll | CPU Phase D | load |
|---|---|---|---|---|---|---|
| ru_phy_tx_#0 | P:ru_emulator.cpp:747 | **TX samples**: DL baseband + `tx_streamer::send` + TX flow control | FIFO max() (98) | partly: 10 us sleep loop (lower_phy…cpp:89-92) | 6 [measured] | 27% |
| ru_phy_rx_#0 | P:ru_emulator.cpp:752 | **RX samples**: `rx_streamer::recv` + RX FC replies | FIFO max()-2 (96) | no, blocks in poll(≤200 ms) | 7 | 10% |
| ru_phy_ul_#0 | P:ru_emulator.cpp:757 | UL demod of RX buffers (no UHD I/O) | FIFO max()-1 (97) | no | 8 | 26% |
| ru_phy_hp_#0 | P:ru_emulator.cpp:713 | DL modulation / PRACH (no UHD I/O) | FIFO max()-2 (96) | no | 6 | 21% |
| ru_radio_#0 | P:ru_emulator.cpp:688 | `recv_async_msg` loop (async events only) | OTHER (no_realtime) | yes, soft: 100 us sleep loop | 8 | 1% |
| uhd_ctrl_ep0001 | U:host/lib/rfnoc/chdr_ctrl_endpoint.cpp:39-42 (made at U:host/lib/rfnoc/link_stream_manager.cpp:184-185) | receives all CHDR ctrl responses + async msgs for the control EPID 0x0001 | inherits RR 89 | **yes**: `get_recv_buff(0)` + `sleep_for(1ns)` loop, `:129-174` | 12 | 100% |
| action_handler | U:host/lib/rfnoc/graph.cpp:81-83 | runs graph actions (tx/rx events, overrun restart, tune) | inherits RR 89 | no, condvar wait (~graph.cpp:629-640) | 12 | 0% |
| uhd_log | U:host/lib/utils/log.cpp:279-281 | UHD log consumer | inherits RR 89 | no | 12 | 0% |
| `ru_emulator` (would be `uhd_log_fp_dummy`) | U:host/lib/utils/log.cpp:299-301 | fast-path log drain; dummy because ProtO-RU sets UHD_LOG_FASTPATH_DISABLE (radio_uhd_impl.cpp:187) | inherits RR 89 | no | 13 | 0% [inferred identity] |
| `ru_emulator` (would be `mpmd_claimer_task`) | U:host/lib/usrp/mpmd/mpmd_mboard_impl.cpp:401-422 via U:host/lib/utils/tasks.cpp:29-31 | re-claims the N310 over gRPC every MPMD_RECLAIM_INTERVAL_MS, dumps MPM logs | inherits RR 89 | no, sleep_until | 13 | 0% [inferred identity] |
| event_engine x20, default-executor, resolver-executor, timer_manager, grpc_global_timer x2 | gRPC library, started by UHD's MPM client channel (U:host/lib/usrp/common/mpm_client.cpp.mako:220-256; linked at U:host/lib/CMakeLists.txt:223-226) | RPC to MPM (claim, sensors, setup) | inherit RR 89 (or from an RR gRPC parent) | no | 13 | ~0% |
| ru_emulator x2 (OTHER) | ProtO-RU main + one other ProtO-RU/OCUDU thread | app main / housekeeping | OTHER | ? | 13 | ~2% [inferred] |
| ru_timing, ru_emu_#0, ru_rx_#0, ru_ofh_tx_#0 | ProtO-RU OFH side | fronthaul, no UHD | FIFO | ru_emu yes | 2/3/4/5 | 48/98/39/21% |

There are no `uhd_log_fastpath`, offload, `uhd_rx`/`uhd_tx` or DPDK threads [source + measured: "no other UHD-named threads"].
Nothing in ProtO-RU links gRPC (no grpc in `P:` sources; the R:docker/Dockerfile.protoru:26,124 install is for UHD) [source].

**Why uhd_ctrl_ep0001 is at 100%.** `recv_worker` calls `_xport->get_recv_buff(0)`. That is `recv(MSG_DONTWAIT)` and then
`poll(fd, timeout 0)` (`U:host/lib/include/uhdlib/transport/udp_common.hpp:106-125`). When it gets nothing, it
`sleep_for(1ns)` (`chdr_ctrl_endpoint.cpp:159-173`). The timeout 0 is hard-coded, and no device or stream arg reaches
it [source]. For an RT task the kernel applies zero timer slack, so the 1 ns nanosleep returns almost at once. The
loop therefore spins with about three syscalls per iteration. Under SCHED_OTHER the default 50 us timer slack would
make it wake roughly every 50 us instead, at a few percent CPU [inferred, kernel hrtimer semantics]. The only knobs
are external: its scheduling class (chrt) or where it is pinned. Recompiling UHD would also work.

## Copies per sample

Per channel per direction: 30.72 Msps x 4 B = 122.9 MB/s, x2 channels = 246 MB/s per direction [inferred arithmetic].
With 8016 B frames (10GbE default, `mpmd_link_if_ctrl_udp.cpp:39,416-423`) that is about 2000 samples per packet,
about 15.4 k packets/s per channel per direction [inferred; actual spp depends on the MTU negotiation].

| step | TX (ru_phy_tx) | RX (ru_phy_rx) |
|---|---|---|
| ProtO-RU side | DL processor writes ci16 into its buffer (computation, not a copy). The pointer goes to UHD unchanged (radio_uhd_tx_stream.cpp:104-115) | UHD writes directly into the ProtO-RU ci16 buffer. It is handed to ru_phy_ul by pointer (lower_phy…cpp:158) |
| UHD convert | **copy 1**: sc16 -> sc16_chdr = plain `memcpy` (U:host/lib/convert/gen_convert_general.py:66-77,252-256), called at tx_streamer_impl.hpp:490 | **copy 2**: sc16_chdr -> sc16 `memcpy`, rx_streamer_impl.hpp:410 |
| kernel | **copy 2**: `send()` copy_from_user into the skb (udp_common.hpp:135) | **copy 1**: `recv()` copy_to_user from the skb into the UHD frame buffer (udp_common.hpp:107/114). Frame pool at U:host/lib/transport/udp_boost_asio_link.cpp:20-29 |
| NIC | DMA, no CPU | DMA, no CPU |

Result: **2 CPU copies per sample per direction**, both in the caller thread. About 4 x 246 MB/s ≈ 1 GB/s of memcpy
traffic in total. The RX socket-side softirq work (GRO/UDP enqueue) runs on the NIC IRQ CPU, not on ru_phy_rx [inferred].

## Syscalls for perf

Data sockets are ordinary blocking boost::asio UDP sockets, connected to the N310 address
(`udp_common.hpp:84-99`). One socket per `get_link()` call, so one per RX channel, one per TX channel and one for
control [source+inferred]. Socket buffers are link_rate x 20 ms (`mpmd_link_if_ctrl_udp.cpp:54,424-425`).

| thread | libc call (source) | x86_64 syscall / tracepoint |
|---|---|---|
| ru_phy_tx_#0 | `::send(fd,…,0)` per packet (udp_common.hpp:135) | `syscalls:sys_enter_sendto` |
| ru_phy_tx_#0 | FC wait: `recv(MSG_DONTWAIT)` then `poll(≤1 ms)` + `recv` on TX socket (inline_io_service.cpp:282-284 -> udp_common.hpp:106-114) | `sys_enter_recvfrom`, `sys_enter_poll` |
| ru_phy_tx_#0 | `sleep_for(10us)` throttle (lower_phy…cpp:91). ENOBUFS retry 1 us (udp_common.hpp:139) | `sys_enter_clock_nanosleep` |
| ru_phy_rx_#0 | `recv(MSG_DONTWAIT)`. If it is empty, `poll(200 ms)` + `recv(…,0)` | `sys_enter_recvfrom`, `sys_enter_poll` |
| ru_phy_rx_#0 | FC response `::send` (chdr_rx_data_xport.hpp:388 -> udp_common.hpp:135) | `sys_enter_sendto` |
| uhd_ctrl_ep0001 | `recv(MSG_DONTWAIT)` + `poll(0)` + `sleep_for(1ns)` loop | `recvfrom`, `poll`, `clock_nanosleep` (high rate) |
| ru_radio_#0 | `sleep_for(100us)` (tx_async_msg_queue.cpp:42) | `sys_enter_clock_nanosleep` |

glibc on x86_64 implements `recv`/`send` with the `recvfrom`/`sendto` syscalls, and `poll` usually with `poll`. Some
glibc builds use `ppoll`, so trace both [inferred; check once with `strace -f -c -p <tid>`]. There is no
`recvmsg`/`recvmmsg`/`sendmmsg` anywhere in this path [source]. Filter by `comm`. The two RR `ru_emulator` threads share
the main thread's comm, so filter them by TID.

## Pinning recommendation

Proposed plan: ru_timing=2 ru_emu=3 ru_rx=4 ru_ofh_tx=5 ru_phy_hp=6 ru_phy_tx=6 ru_phy_rx=7 ru_radio=8 (9 idle)
ru_phy_ul=10 (11 idle) uhd_ctrl_ep0001=12 *=13.

1. **Keep ru_phy_tx and ru_phy_rx on isolated P-cores.** They are the only threads that touch the NIC (sendto/recvfrom
   + memcpy), and every kernel network-stack cycle for TX lands on their CPU [source+inferred]. ru_phy_tx (FIFO 98)
   sharing CPU 6 with ru_phy_hp (FIFO 96) is acceptable: tx preempts hp, and the measured total is 50% [measured].
2. **ru_radio does not need a P-core** (option, not adopted: the committed plan keeps the Phase D placement, ru_radio
   alone on 8, until an RF run tests a change). It is SCHED_OTHER, 1% load, sleeps 100 us at a time, and only reports
   underflow/late events [source+measured]. Pinning it alone on 8 with 9 idle wastes one physical core. Its 100 us wakeups
   also keep the tick running on a nohz_full CPU [inferred]. Recommend **ru_radio=13**. If an E-core is wanted only for
   it, use 14, away from the spinning ctrl_ep. The freed core 8/9 can then give ru_phy_tx its own core (ru_phy_tx=8, hp stays on 6),
   or host ru_phy_ul, so that 10/11 stays spare. Either way each sample-moving thread gets a physical core with an idle sibling.
3. **uhd_ctrl_ep0001=12 alone.** It will spin at 100% while it is RR. That is harmless on an E-core that has nothing else
   on it [measured]. **Name `action_handler=13 uhd_log=13` explicitly.** They inherited a restricted affinity, and
   `pin_threads.py` only applies `*` to threads whose affinity is the whole cpuset (`R:tools/bench/pin_threads.py:58-60`).
   That is presumably why they sat on 12 behind a same-priority RR spinner [inferred].
   Optional experiment: `chrt -o -p 0 <ctrl_ep tid>` (SCHED_OTHER) should drop it to a few percent, at the cost of
   about 50 us extra latency on control ACKs and async events [inferred]. Run it only with an RF check (see open questions).
   ProtO-RU's comment warns that starving UHD control threads causes ctrl-ACK timeouts (`P:apps/examples/ofh/ru_emulator.cpp:684-688`).
4. Leave `*`=13 for gRPC, both unnamed UHD threads and ProtO-RU main. They are all ~0% RR [measured].
5. Keep the 10 GbE NIC's IRQs (the port facing the N310) off 2-11. Put them on an E-core that is not 12, e.g. 14-15, so RX
   softirq work does not land on 12 behind the spinner [inferred].
6. Note: the HT-sibling pairs (2,3) and (4,5) carry two RT threads each, including ru_emu at 98% busy-poll. That is outside UHD,
   but those pairs, not UHD, are the likeliest place for SMT interference [measured+inferred].

## Open questions (need the RF/bench measurement)

1. Actual samples per packet and packet rate. Measure sendto/recvfrom byte counts with perf. This depends on the
   negotiated MTU (`calculate_udp_link_params`, `mpmd_link_if_ctrl_udp.cpp:434-439`).
2. How often ru_phy_tx blocks on TX flow control. Count `sys_enter_poll` and `recvfrom` from ru_phy_tx. Many of them mean
   the N310 buffer is full and TX runs ahead of time.
3. RF/KPI effect of demoting uhd_ctrl_ep0001 to SCHED_OTHER: underflow/late counts and control timeouts.
4. Confirm that the two RR `ru_emulator` threads are `mpmd_claimer_task` and `uhd_log_fp_dummy`
   (`/proc/<tid>/stack`, `gdb thread apply all bt`, or wakeups every MPMD_RECLAIM_INTERVAL_MS).
5. Why action_handler and uhd_log had affinity {12}, i.e. which thread created them and what its affinity was at
   creation. Check Cpus_allowed in `/proc/<tid>/status` at start-up.
6. Which CPU services the NIC IRQs and how much softirq time it carries (`/proc/interrupts`, `mpstat -I SCPU`).
7. Whether glibc emits `poll` or `ppoll` for `::poll` in the container image.
