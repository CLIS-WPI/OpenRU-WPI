# Time synchronization (hardware week)

Phase 1 runs DU and ProtO-RU on the **same host**, so PTP is not required for Milestones 0–5. This note records how the two-host PTP setup from ProtO-RU will be reproduced in the hardware week.

## Source

Upstream: `external/proto-ru/proto-ru/TIME_SYNC.md` (LLS-C1 with linuxptp G.8275.1).

## Hardware-week plan

1. Disable NTP on DU and RU hosts (`timedatectl set-ntp false`).
2. Install linuxptp v4.4 on both hosts.
3. DU host: `ptp4l` as grandmaster using `proto-ru/ptp-conf-files/ptp-gm.cfg` on the fronthaul NIC that has hardware timestamping.
4. RU host: `ptp4l` as slave with `ptp-slave.cfg`, then `phc2sys` to discipline system clock from PHC.
5. Confirm offset/path delay in logs before bringing up OFH.

## Phase 1 status

| Item | Status |
| --- | --- |
| Same-host AF_PACKET fronthaul | used for M0+ |
| Hardware PTP NIC | absent / not required for Phase 1 |
| PREEMPT_RT kernel | absent / not required for Phase 1 |
