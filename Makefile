# OpenRU software — Phase 1 (GPU1 lane)
ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
include $(ROOT)/docker/versions.env
export

COMPOSE := docker compose --env-file $(ROOT)/docker/versions.env -f $(ROOT)/docker/compose.yml
COMPOSE_CORE := $(COMPOSE) -f $(ROOT)/docker/compose.core.yml
SMOKE_SECS ?= 60
REPORTS := $(ROOT)/docs/reports

.PHONY: help preflight gpu-check build build-core build-protoru down logs \
        smoke smoke-fh smoke-core fetch-golden compare-plmn

help:
	@echo "OpenRU targets (GPU1 only: $(OPENRU_GPU_UUID))"
	@echo "  make smoke-fh     M0 gate: DU(no_core)+ProtO-RU emulator, $(SMOKE_SECS)s"
	@echo "  make smoke-core   NG Setup only (required before M4)"
	@echo "  make smoke        alias for smoke-fh"

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

smoke-fh: preflight
	@mkdir -p $(REPORTS)
	@rm -f $(REPORTS)/caps-protoru.md $(REPORTS)/caps-du.md
	@echo "[smoke-fh] DU(no_core)+ProtO-RU emulator, $(SMOKE_SECS)s, GPU1 $(OPENRU_GPU_UUID)"
	@$(COMPOSE) --profile fh --profile core --profile full down --remove-orphans >/dev/null 2>&1 || true
	@DU_CONFIG_PATH=$(ROOT)/profiles/baseline/du-fh.yml \
	  PROTORU_CONFIG_PATH=$(ROOT)/profiles/baseline/protoru.yml \
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
	    --secs $(SMOKE_SECS); \
	  rc=$$?; \
	  $(COMPOSE) --profile fh down --remove-orphans >/dev/null 2>&1; \
	  if [ $$rc -eq 2 ]; then echo "[smoke-fh] SOFT-FAIL (lates measured; see OPEN_QUESTIONS)"; exit 2; fi; \
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

fetch-golden:
	@echo "Golden IQ fetch not configured yet (Milestone 1)."
