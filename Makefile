# OpenRU — Phase 1
ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
include $(ROOT)/docker/versions.env
# lab.env is required for runtime GPU/cpuset; preflight enforces it.
-include $(ROOT)/docker/lab.env
export

COMPOSE := docker compose --env-file $(ROOT)/docker/versions.env \
	$(if $(wildcard $(ROOT)/docker/lab.env),--env-file $(ROOT)/docker/lab.env,) \
	-f $(ROOT)/docker/compose.yml
COMPOSE_CORE := $(COMPOSE) -f $(ROOT)/docker/compose.core.yml
SMOKE_SECS ?= 60
REPORTS := $(ROOT)/docs/reports

CAPTURE_SECS ?= 10
PROFILE ?= baseline
# Prefer lab.env MARCH; else versions.env MARCH_DEFAULT; else x86-64-v3.
ifeq ($(origin MARCH),undefined)
  MARCH := $(if $(MARCH_DEFAULT),$(MARCH_DEFAULT),x86-64-v3)
endif


.PHONY: help preflight gpu-check build build-core build-protoru down logs \
        smoke smoke-fh smoke-core fetch-golden replay-golden compare-plmn capture

help:
	@echo "OpenRU targets (GPU: $$(test -f $(ROOT)/docker/lab.env && echo set || echo 'lab.env MISSING'))"
	@echo "  make smoke-fh     M0 gate: DU(no_core)+ProtO-RU emulator, $(SMOKE_SECS)s"
	@echo "  make smoke-core   NG Setup only (required before M4)"
	@echo "  make smoke        alias for smoke-fh"
	@echo "  make capture      M1: OFH pcap capture ($(CAPTURE_SECS)s, PROFILE=$(PROFILE))"
	@echo "  make fetch-golden Fetch golden .cf32 via OPENRU_GOLDEN_URL + verify SHA256"
	@echo "  make replay-golden CI gate: fh_replay vs golden, 0 differing samples"

preflight:
	@$(ROOT)/scripts/gpu1_preflight.sh

gpu-check: preflight
	@docker run --rm \
	  --gpus "device=$(OPENRU_GPU_UUID)" \
	  -e NVIDIA_VISIBLE_DEVICES=$(OPENRU_GPU_UUID) \
	  --cap-add NET_RAW --cap-add NET_ADMIN --cap-add SYS_NICE --cap-add IPC_LOCK \
	  --ulimit rtprio=99 --ulimit memlock=-1 \
	  --cpuset-cpus=$(PROTORU_CPUSET) \
	  nvidia/cuda:12.6.0-base-ubuntu22.04 \
	  bash -lc 'nvidia-smi -L; chrt -f 50 true; \
	    echo "$$(nvidia-smi -L)" | grep -q "$(OPENRU_FORBIDDEN_GPU_UUID)" && exit 2 || true; \
	    echo "$$(nvidia-smi -L)" | grep -q "$(OPENRU_GPU_UUID)"'

build-core:
	$(COMPOSE) build core

build-protoru: preflight
	$(COMPOSE) --profile build build ocudu

build: build-core build-protoru

down:
	-$(COMPOSE) --profile fh --profile core --profile full down --remove-orphans

logs:
	$(COMPOSE) --profile fh logs --tail=200 du protoru

compare-plmn:
	@$(ROOT)/scripts/compare_plmn.sh \
	  $(ROOT)/profiles/baseline/du-core.yml \
	  $(ROOT)/external/proto-ru/docker/open5gs/open5gs-5gc.yml

smoke: smoke-fh

# PROTORU_PROFILE=emulator (M0) | null (M1+). Default emulator for backward compat.
PROTORU_PROFILE ?= emulator
PROTORU_YML := $(if $(filter null,$(PROTORU_PROFILE)),$(ROOT)/profiles/baseline/protoru-null.yml,$(ROOT)/profiles/baseline/protoru.yml)

smoke-fh: preflight
	@mkdir -p $(REPORTS)
	@rm -f $(REPORTS)/caps-protoru.md $(REPORTS)/caps-du.md
	@echo "[smoke-fh] DU(no_core)+ProtO-RU $(PROTORU_PROFILE), $(SMOKE_SECS)s, GPU $(OPENRU_GPU_UUID)"
	@$(COMPOSE) --profile fh --profile core --profile full down --remove-orphans >/dev/null 2>&1 || true
	@DU_CONFIG_PATH=$(ROOT)/profiles/baseline/du-fh.yml \
	  PROTORU_CONFIG_PATH=$(PROTORU_YML) \
	  $(COMPOSE) --profile fh up -d du protoru
	@sleep 4
	@cid_ru=$$($(COMPOSE) --profile fh ps -q protoru); \
	  cid_du=$$($(COMPOSE) --profile fh ps -q du); \
	  test -n "$$cid_ru" && test -n "$$cid_du" || { echo "FAIL: containers not up"; $(COMPOSE) --profile fh ps; exit 1; }; \
	  docker exec $$cid_ru nvidia-smi -L | tee $(REPORTS)/smoke-gpu.txt; \
	  grep -q "$(OPENRU_GPU_UUID)" $(REPORTS)/smoke-gpu.txt; \
	  ! grep -q "$(OPENRU_FORBIDDEN_GPU_UUID)" $(REPORTS)/smoke-gpu.txt; \
	  test "$$(grep -c '^GPU ' $(REPORTS)/smoke-gpu.txt)" = "1"; \
	  $(ROOT)/scripts/verify_caps.sh $$cid_ru eth0 $(REPORTS)/caps-protoru.md; \
	  $(ROOT)/scripts/verify_caps.sh $$cid_du eth0 $(REPORTS)/caps-du.md
	@echo "[smoke-fh] waiting for first ProtO-RU KPI with RX_TOTAL>0..."
	@ready=0; \
	  for i in $$(seq 1 45); do \
	    if $(COMPOSE) --profile fh logs --no-color --tail=20 protoru 2>/dev/null | \
	       sed 's/\x1b\[[0-9;]*m//g' | \
	       grep -EEq '\|[[:space:]]*[0-9]{2}:[0-9]{2}:[0-9]{2}[[:space:]]*\|[[:space:]]*[0-9]+[[:space:]]*\|[[:space:]]*[1-9][0-9]*[[:space:]]*\|'; then \
	      ready=1; break; \
	    fi; \
	    sleep 1; \
	  done; \
	  if [ $$ready -ne 1 ]; then echo "FAIL: no OFH RX in ProtO-RU KPI within 45s"; \
	    $(COMPOSE) --profile fh logs --no-color --tail=40 protoru du; exit 1; fi
	@echo "[smoke-fh] OFH traffic seen; measuring $(SMOKE_SECS)s..."
	@sleep $(SMOKE_SECS)
	@cid_ru=$$($(COMPOSE) --profile fh ps -q protoru); \
	  cid_du=$$($(COMPOSE) --profile fh ps -q du); \
	  { echo "===== compose logs: du ====="; $(COMPOSE) --profile fh logs --no-color du 2>&1; \
	    echo "===== /tmp/gnb.log ====="; docker exec $$cid_du cat /tmp/gnb.log 2>/dev/null || true; \
	  } > $(REPORTS)/smoke-fh-du.log; \
	  { echo "===== compose logs: protoru ====="; $(COMPOSE) --profile fh logs --no-color protoru 2>&1; \
	    echo "===== /tmp/proto-ru.log ====="; docker exec $$cid_ru cat /tmp/proto-ru.log 2>/dev/null || true; \
	  } > $(REPORTS)/smoke-fh-ru.log
	@set +e; \
	  python3 $(ROOT)/scripts/parse_smoke_fh.py \
	    --du-log $(REPORTS)/smoke-fh-du.log \
	    --ru-log $(REPORTS)/smoke-fh-ru.log \
	    --secs $(SMOKE_SECS) \
	    --json-out $(REPORTS)/smoke-fh-kpi.json \
	    --hist-out $(REPORTS)/smoke-fh-late-hist.csv; \
	  rc=$$?; \
	  $(COMPOSE) --profile fh down --remove-orphans >/dev/null 2>&1; \
	  if [ $$rc -ne 0 ]; then echo "[smoke-fh] FAIL rc=$$rc"; exit $$rc; fi; \
	  echo "[smoke-fh] PASS"

smoke-core: preflight
	@mkdir -p $(REPORTS)
	@echo "[smoke-core] NG Setup against Open5GS"
	@$(ROOT)/scripts/compare_plmn.sh \
	  $(ROOT)/profiles/baseline/du-core.yml \
	  $(ROOT)/external/proto-ru/docker/open5gs/open5gs-5gc.yml \
	  $(REPORTS)/plmn-compare.md
	@$(COMPOSE_CORE) --profile fh --profile core --profile full down --remove-orphans >/dev/null 2>&1 || true
	@DU_CONFIG_PATH=$(ROOT)/profiles/baseline/du-core.yml \
	  $(COMPOSE_CORE) --profile core up -d core
	@echo "[smoke-core] waiting for core healthy..."
	@for i in $$(seq 1 60); do \
	  $(COMPOSE_CORE) --profile core ps core 2>/dev/null | grep -qi healthy && break; \
	  sleep 2; \
	 done
	@DU_CONFIG_PATH=$(ROOT)/profiles/baseline/du-core.yml \
	  $(COMPOSE_CORE) --profile core up -d --no-deps du
	@ok=0; \
	  for i in $$(seq 1 45); do \
	    $(COMPOSE_CORE) --profile core logs --no-color du 2>&1 > $(REPORTS)/smoke-core-du.log; \
	    docker exec $$($(COMPOSE_CORE) --profile core ps -q du) cat /tmp/gnb.log 2>/dev/null >> $(REPORTS)/smoke-core-du.log || true; \
	    if grep -Eiq 'NGSetupResponse|NG Setup (Procedure )?Response|Connected to AMF|NG Setup successful' $(REPORTS)/smoke-core-du.log; then ok=1; break; fi; \
	    if grep -Eiq 'NGSetupFailure|NG Setup Procedure".*failed|unknown-PLMN|CU-CP failed to connect to AMF' $(REPORTS)/smoke-core-du.log; then \
	      echo "[smoke-core] saw NG Setup failure in logs"; break; \
	    fi; \
	    sleep 1; \
	  done; \
	  echo "--- subscriber (IMSI prefix 00101) ---" | tee -a $(REPORTS)/smoke-core-du.log; \
	  grep SUBSCRIBER $(ROOT)/external/proto-ru/docker/open5gs/open5gs.env | tee -a $(REPORTS)/smoke-core-du.log; \
	  $(COMPOSE_CORE) --profile core down --remove-orphans >/dev/null 2>&1; \
	  if [ $$ok -ne 1 ]; then echo "[smoke-core] FAIL: no NG Setup Response"; tail -40 $(REPORTS)/smoke-core-du.log; exit 1; fi; \
	  echo "[smoke-core] PASS"

capture: preflight
	@CAPTURE_SECS=$(CAPTURE_SECS) PROFILE=$(PROFILE) $(ROOT)/scripts/capture_ofh.sh

fetch-golden:
	@chmod +x $(ROOT)/scripts/fetch_golden.sh
	@$(ROOT)/scripts/fetch_golden.sh

# CPU replay vs stored golden (requires fetched .cf32 under testdata/golden/).
# Replays each profile twice offline when generating goldens; CI verifies the
# on-disk golden still matches a fresh replay dump. baseline uses the full 10 s
# pcap so the SFN-0 window has 4000 slots; b40/b100 fit in their _3s slices.
replay-golden: preflight
	@mkdir -p $(REPORTS)
	@echo "[replay-golden] profiles=baseline b40 b100 (OPENRU_TAG=$${OPENRU_TAG:-m1})"
	@set -e; \
	  for prof in baseline b40 b100; do \
	    echo "[replay-golden] $$prof"; \
	    test -f testdata/golden/$$prof/MANIFEST.json; \
	    test -s testdata/golden/$$prof/port0.cf32 || { \
	      echo "FAIL: missing golden IQ for $$prof — run make fetch-golden"; exit 1; }; \
	    pcap=testdata/pcap/$${prof}_3s.pcapng; \
	    if [ "$$prof" = "baseline" ]; then pcap=testdata/pcap/baseline.pcapng; fi; \
	    $(ROOT)/scripts/replay_iq_dump.sh $$prof $$pcap \
	      $(REPORTS)/replay-golden-$$prof 1.0; \
	    python3 $(ROOT)/tools/iq_compare/iq_compare.py \
	      --dut $(REPORTS)/replay-golden-$$prof \
	      --golden testdata/golden/$$prof \
	      --by-slot --threshold 0; \
	  done; \
	  echo "[replay-golden] PASS"
