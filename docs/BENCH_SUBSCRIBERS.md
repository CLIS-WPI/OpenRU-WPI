# Bench subscribers (Open5GS provisioning)

The bench modems need SIM credentials in the Open5GS subscriber database. **Key
material never goes into git, PRs, issues or chat**: it lives only in a local,
owner-readable file on the bench host (see `AGENTS.md`, "Remote access (do not
commit)" and `scripts/check_no_secrets.sh`).

## Local file

```bash
mkdir -p ~/Desktop/OpenRU/secrets
chmod 700 ~/Desktop/OpenRU/secrets
$EDITOR ~/Desktop/OpenRU/secrets/subscribers.env
chmod 600 ~/Desktop/OpenRU/secrets/subscribers.env
```

`scripts/add_subscriber.sh` reads it (default `~/Desktop/OpenRU/secrets/subscribers.env`,
override with `OPENRU_SUBSCRIBERS_FILE` or the first argument). It **refuses a
group/world-readable file**, never prints K or OPc, and passes the documents to
the core container over stdin (never as command-line arguments).

Format — one block per subscriber, blank line between blocks:

```ini
# Modem A
imsi=001010000000001
k=<32 hex digits>
opc=<32 hex digits>
amf=8000          # optional, 1-4 hex digits (default 8000)
sst=1             # optional, must be 1
dnn=internet      # optional, default internet
qci=9             # optional, default 9
sqn=000000000060  # optional, 12 hex digits (see SQN/AUTS below)

# Modem B
imsi=001010000000006
k=<32 hex digits>
opc=<32 hex digits>
```

## Bench subscribers

| Subscriber | IMSI | PLMN | SST | DNN |
|---|---|---|---|---|
| Modem A | `001010000000001` | `00101` | 1 | `internet` |
| Modem B | `001010000000006` | `00101` | 1 | `internet` |

IMSI prefix `00101` = PLMN 00101 (MCC 001, MNC 01). The core configuration
(`external/proto-ru/docker/open5gs/open5gs-5gc.yml`) has `plmn_support` with
`sst: 1` on the AMF and `s_nssai: sst: 1` on the NSSF, and the SMF has **no DNN
allow-list** — the DNN is taken from the subscriber's session entry, so `internet`
(as configured on the modems) is the correct value. SST must be `1`; the script
rejects anything else.

## Run it

```bash
# core first
BENCH=1 make up UP_PROFILE=core

# validate without writing
BENCH=1 scripts/add_subscriber.sh --dry-run

# provision (adds or updates; prints IMSIs only)
BENCH=1 scripts/add_subscriber.sh

# inspect (IMSI only, never dump the key fields)
docker compose --env-file docker/versions.env --env-file docker/bench.env \
  -f docker/compose.yml -f docker/compose.cpu.yml exec -T core \
  mongosh --quiet open5gs --eval 'db.subscribers.find({}, {imsi:1, sqn:1, _id:0}).toArray()'
```

## SQN / AUTS resynchronisation

The SIM programmer set the HSS SQN to **96** (decimal; `000000000060` in the
6-byte hex form Open5GS stores). You do **not** need to set `sqn` in the file:
Open5GS's UDM implements the AUTS resynchronisation from 3GPP TS 33.102 C.3.4 —
on an authentication failure with a synchronisation cause it de-conceals the
SQN from AUTS, verifies MAC-S, sets the new SQN to `(SQN_MS + 32 + 1) & MAX_SQN`
and PATCHes the authentication subscription
([`src/udm/nudm-handler.c`, `udm_nudm_ueau_handle_get`](https://github.com/open5gs/open5gs/blob/main/src/udm/nudm-handler.c)).
The first attach then succeeds and the stored SQN advances.

If the first attach still fails, look for (in `docker compose logs core`):

- `[imsi-...] No AUTS` / `No RAND` — malformed resync request;
- `[imsi-...] Invalid RAND` — the UDM no longer has the RAND that produced the
  vector (retry from a clean UE state);
- `[imsi-...] Re-synch MAC failed` — **K/OPc do not match the SIM** (fix the
  file; nothing else will work);
- AMF: authentication failure / `Synchronization failure` (cause 21) with no UDM
  resync line — align the values manually: set `sqn=000000000060` (the
  programmer's 96) in the file and re-run, or update the SIM's SQN.

Known upstream caveat: Open5GS 2.7.7 has a UDM crash on the resync PATCH path for
a fresh UE context (open5gs#4418). The bench core pins `OPEN5GS_VERSION=v2.7.6`;
if UDM aborts during resync, pre-set `sqn` as above so no resync is needed.
