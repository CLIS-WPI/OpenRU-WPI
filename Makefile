# OpenRU — Phase 1
ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
include $(ROOT)/docker/versions.env
# Bench-bundle host (no GPU): BENCH=1 selects docker/bench.env and the CPU
# overlay, and points preflight at the bench env (docs/BENCH_BUNDLE.md).
ifeq ($(BENCH),1)
  include $(ROOT)/docker/bench.env
  COMPOSE_ENV_FILE := $(ROOT)/docker/bench.env
  COMPOSE_OVERLAY := -f $(ROOT)/docker/compose.cpu.yml
  OPENRU_PREFLIGHT_ENV := $(ROOT)/docker/bench.env
endif
# lab.env is required for runtime GPU/cpuset; preflight enforces it.
-include $(ROOT)/docker/lab.env
export
# Image provenance (bench-release overrides these; default to this tree).
export OPENRU_GIT_COMMIT ?= $(shell git -C "$(ROOT)" rev-parse HEAD 2>/dev/null || echo unknown)
export OPENRU_GIT_SUBMODULE ?= $(shell git -C "$(ROOT)/external/proto-ru" rev-parse HEAD 2>/dev/null || echo unknown)
export OPENRU_BUILD_DATE ?= $(shell date -u +%Y-%m-%dT%H:%M:%SZ)

COMPOSE := docker compose --env-file $(ROOT)/docker/versions.env \
	$(if $(COMPOSE_ENV_FILE),--env-file $(COMPOSE_ENV_FILE),$(if $(wildcard $(ROOT)/docker/lab.env),--env-file $(ROOT)/docker/lab.env,)) \
	$(COMPOSE_OVERLAY) \
	-f $(ROOT)/docker/compose.yml
COMPOSE_CORE := $(COMPOSE) -f $(ROOT)/docker/compose.core.yml
SMOKE_SECS ?= 60
REPORTS := $(ROOT)/docs/reports/raw

CAPTURE_SECS ?= 12
PROFILE ?= baseline
# Prefer lab.env MARCH; else versions.env MARCH_DEFAULT; else x86-64-v3.
ifeq ($(origin MARCH),undefined)
  MARCH := $(if $(MARCH_DEFAULT),$(MARCH_DEFAULT),x86-64-v3)
endif


.PHONY: help preflight gpu-check build build-core build-protoru down logs \
        smoke smoke-fh smoke-core fetch-golden replay-golden compare-plmn capture \
        bench-preflight up bench-release bench-ship check-no-secrets

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

# Bench-bundle host preflight (P/E topology, kernel isolation, X710, MTU 9000,
# hwlatdetect, UHD/N310 MPM match). See docs/BENCH_BUNDLE.md.
BENCH_ENV ?= docker/bench.env
bench-preflight:
	@BENCH_ENV=$(BENCH_ENV) $(ROOT)/scripts/bench_preflight.sh

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

# Repeatable bench-image release (artifacts outside the repo; see docs/BENCH_BUNDLE.md).
# Artifact root: command line, docker/bench.local.env (gitignored), or $HOME/openru-artifacts.
OPENRU_ARTIFACTS_DIR ?=
BENCH_RELEASE_KEEP ?= 5
bench-release:
	@$(if $(OPENRU_ARTIFACTS_DIR),OPENRU_ARTIFACTS_DIR="$(OPENRU_ARTIFACTS_DIR)") \
	  BENCH_RELEASE_KEEP=$(BENCH_RELEASE_KEEP) \
	  $(ROOT)/scripts/bench_release.sh

# HOST from the command line or docker/bench.local.env — never a committed hostname.
bench-ship:
	@$(if $(OPENRU_ARTIFACTS_DIR),OPENRU_ARTIFACTS_DIR="$(OPENRU_ARTIFACTS_DIR)") \
	  HOST="$(HOST)" RELEASE="$(RELEASE)" \
	  $(ROOT)/scripts/bench_ship.sh

UP_PROFILE ?= fh
up:
	@BENCH=$(BENCH) $(ROOT)/scripts/up.sh $(UP_PROFILE)

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
PROTORU_YML := $(if $(filter null,$(PROTORU_PROFILE)),$(ROOT)/profiles/$(PROFILE)/protoru-null.yml,$(ROOT)/profiles/$(PROFILE)/protoru.yml)

smoke-fh: preflight
	@mkdir -p $(REPORTS)
	@rm -f $(REPORTS)/caps-protoru.md $(REPORTS)/caps-du.md
	@echo "[smoke-fh] DU(no_core)+ProtO-RU $(PROTORU_PROFILE), $(SMOKE_SECS)s, GPU $(OPENRU_GPU_UUID)"
	@$(COMPOSE) --profile fh --profile core --profile full down --remove-orphans >/dev/null 2>&1 || true
	@DU_CONFIG_PATH=$(ROOT)/profiles/$(PROFILE)/du-fh.yml \
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
	@echo "[smoke-fh] OFH traffic seen; quiet-host pre-check..."
	@python3 $(ROOT)/scripts/quiet_host.py --once \
	   --reserved "$(PROTORU_CPUSET),$(DU_CPUSET)" \
	   --containers openru-protoru-1,openru-du-1 \
	   --out $(REPORTS)/smoke-fh-hostcheck-pre.json || \
	   { echo "[smoke-fh] INVALID: busy host before measurement (see $(REPORTS)/smoke-fh-hostcheck-pre.json)"; \
	     $(COMPOSE) --profile fh down --remove-orphans >/dev/null 2>&1; exit 3; }
	@echo "[smoke-fh] measuring $(SMOKE_SECS)s with quiet-host monitor..."
	@nohup python3 $(ROOT)/scripts/quiet_host.py --monitor --interval 30 \
	   --reserved "$(PROTORU_CPUSET),$(DU_CPUSET)" \
	   --containers openru-protoru-1,openru-du-1 \
	   --out $(REPORTS)/smoke-fh-hostcheck.json >/dev/null 2>&1 & echo $$! > /tmp/openru-hostcheck.pid
	@sleep $(SMOKE_SECS)
	@kill $$(cat /tmp/openru-hostcheck.pid) 2>/dev/null || true; rm -f /tmp/openru-hostcheck.pid; sleep 1
	@cid_ru=$$($(COMPOSE) --profile fh ps -q protoru); \
	  cid_du=$$($(COMPOSE) --profile fh ps -q du); \
	  { echo "===== compose logs: du ====="; $(COMPOSE) --profile fh logs --no-color du 2>&1; \
	    echo "===== /tmp/gnb.log ====="; docker exec $$cid_du cat /tmp/gnb.log 2>/dev/null || true; \
	  } > $(REPORTS)/smoke-fh-du.log; \
	  { echo "===== compose logs: protoru ====="; $(COMPOSE) --profile fh logs --no-color protoru 2>&1; \
	    echo "===== /tmp/proto-ru.log ====="; docker exec $$cid_ru cat /tmp/proto-ru.log 2>/dev/null || true; \
	  } > $(REPORTS)/smoke-fh-ru.log
	@python3 -c "import json,sys; d=json.load(open('$(REPORTS)/smoke-fh-hostcheck.json')); sys.exit(0 if d.get('valid') else 3)" || \
	   { echo "[smoke-fh] INVALID: busy host during measurement (see $(REPORTS)/smoke-fh-hostcheck.json)"; \
	     $(COMPOSE) --profile fh down --remove-orphans >/dev/null 2>&1; exit 3; }
	@set +e; \
	  python3 $(ROOT)/scripts/parse_smoke_fh.py \
	    --du-log $(REPORTS)/smoke-fh-du.log \
	    --ru-log $(REPORTS)/smoke-fh-ru.log \
	    --secs $(SMOKE_SECS) \
	    --json-out $(REPORTS)/smoke-fh-kpi.json \
	    --hist-out $(REPORTS)/smoke-fh-late-hist.csv \
	    --hostcheck $(REPORTS)/smoke-fh-hostcheck.json; \
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
# Every run also enforces the permanent golden checks: dump starts at the golden's window slot, all expected DL
# User-Plane slots have non-zero energy on their expected ports (`expected_slots_by_port`, derived from the
# profile's dl_port_id and the pcap's non-zero U-plane payload); declared-silent ports are zero; no UL-slot leakage;
# expected non-empty count within tolerance.
# The window is tracked in testdata/golden/<profile>/window.json and is reused for the dump gate and the check.
# REPLAY_PROFILES restricts the loop (tests/replay-golden/run.sh uses one profile per run); the default keeps the
# historical baseline b40 b100 sweep.
REPLAY_PROFILES ?= baseline b40 b100
# Golden tree (image-specific): the v4 goldens live in testdata/golden; a v3
# set would live in testdata/golden-v3 (see docs/BENCH_BUNDLE.md).
GOLDEN_ROOT ?= testdata/golden
# Force the replay image tag instead of the one recorded in the MANIFEST
# (cross-image replay: e.g. OPENRU_REPLAY_TAG=v1-candidate-v3).
replay-golden: preflight
	@mkdir -p $(REPORTS)
	@echo "[replay-golden] profiles=$(REPLAY_PROFILES) (OPENRU_TAG=$${OPENRU_TAG:-m1})"
	@set -e; \
	  for prof in $(REPLAY_PROFILES); do \
	    echo "[replay-golden] $$prof"; \
	    test -f $(GOLDEN_ROOT)/$$prof/MANIFEST.json; \
	    if python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("status")=="deferred" else 1)' $(GOLDEN_ROOT)/$$prof/MANIFEST.json; then \
	      echo "[replay-golden] $$prof deferred — skipping"; continue; \
	    fi; \
	    test -f $(GOLDEN_ROOT)/$$prof/window.json || { echo "FAIL: missing golden window for $$prof"; exit 1; }; \
	    test -s testdata/pcap/$$prof.pcapng || { echo "FAIL: missing pcap for $$prof"; exit 1; }; \
	    test -s $(GOLDEN_ROOT)/$$prof/port0.cf32 || { \
	      echo "FAIL: missing golden IQ for $$prof — run make fetch-golden"; exit 1; }; \
	    if python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("host_limited") else 1)' $(GOLDEN_ROOT)/$$prof/MANIFEST.json; then \
	      if [ "$${RUN_HOST_LIMITED:-0}" != "1" ]; then \
	        reason=$$(python3 -c 'import json,sys; h=json.load(open(sys.argv[1]))["host_limited"]; print("{} / {} runs passed: {}".format(h.get("passes"), h.get("runs"), h.get("reason")))' $(GOLDEN_ROOT)/$$prof/MANIFEST.json); \
	        echo "[replay-golden] $$prof SKIPPED (host_limited: $$reason)"; continue; \
	      fi; \
	      echo "[replay-golden] $$prof host_limited but RUN_HOST_LIMITED=1 — running on demand"; \
	    fi; \
	    mode=$$(python3 $(ROOT)/tools/golden/manifest_mode.py --manifest $(GOLDEN_ROOT)/$$prof/MANIFEST.json --field lead_mode); \
	    lead=$$(python3 $(ROOT)/tools/golden/manifest_mode.py --manifest $(GOLDEN_ROOT)/$$prof/MANIFEST.json --field lead_us); \
	    sender=$$(python3 $(ROOT)/tools/golden/manifest_mode.py --manifest $(GOLDEN_ROOT)/$$prof/MANIFEST.json --field sender); \
	    tag=$$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("image") or "")' $(GOLDEN_ROOT)/$$prof/MANIFEST.json); \
	    echo "[replay-golden] $$prof image=$${OPENRU_REPLAY_TAG:-$${tag:-$${OPENRU_TAG:-m1}}} (golden image: $$tag)"; \
	    OPENRU_WINDOW_JSON=$(GOLDEN_ROOT)/$$prof/window.json OPENRU_TAG=$${OPENRU_REPLAY_TAG:-$${tag:-$${OPENRU_TAG:-m1}}} \
	      OPENRU_REPLAY_SENDER=$$sender OPENRU_LEAD_MODE=$$mode OPENRU_REPLAY_ALIGN_LEAD_US=$$lead \
	      $(ROOT)/scripts/replay_iq_dump.sh $$prof testdata/pcap/$$prof.pcapng \
	      $(REPORTS)/replay-golden-$$prof 1.0; \
	    python3 $(ROOT)/tools/golden/check.py \
	      --dump $(REPORTS)/replay-golden-$$prof \
	      --window-json $(GOLDEN_ROOT)/$$prof/window.json \
	      --du-config profiles/$$prof/du-fh.yml \
	      --out $(REPORTS)/replay-golden-$$prof-check.json; \
	    python3 $(ROOT)/tools/iq_compare/iq_compare.py \
	      --dut $(REPORTS)/replay-golden-$$prof \
	      --golden $(GOLDEN_ROOT)/$$prof \
	      --by-slot --threshold 0; \
	  done; \
	  echo "[replay-golden] PASS"

# Regenerate the three CPU goldens from fresh MTU-9000 captures: two cold replays each (0 differing samples), then
# install the window, IQ, tx index and MANIFEST into testdata/golden/<profile>/.
gen-golden: preflight
	@OPENRU_TAG=$${OPENRU_TAG:-m1} $(ROOT)/scripts/gen_golden.sh

# ---------------------------------------------------------------- tests/ ---
# Modular test framework (see docs/TESTS.md). `make test` runs one suite/
# profile through tests/<suite>/run.sh, which wraps the existing targets and
# writes docs/reports/runs/<suite>/<date>-<profile>.json.
SUITES := smoke-fh smoke-core replay-golden cuda-standalone cuda-pipeline cuda-scaling

.PHONY: test test-list $(foreach s,$(SUITES),test-$(s))

help-tests:
	@$(MAKE) --no-print-directory test-list

# Remote-access leak check (also a dependency of test-list; install as a pre-commit hook).
check-no-secrets:
	@$(ROOT)/scripts/check_no_secrets.sh

test-list: check-no-secrets
	@echo "Suites (docs/TESTS.md):"
	@for s in $(SUITES); do \
	  profs=""; \
	  for p in $(ROOT)/tests/$$s/profiles/*/; do \
	    [ -d "$$p" ] && profs="$$profs $$(basename $$p)"; \
	  done; \
	  echo "  $$s:$$profs"; \
	done

# env -i: the bare `export` above pushes make's own defaults (e.g.
# PROTORU_PROFILE=emulator) into run.sh, where the profile env files would
# lose to the "caller environment wins" rule. A clean env keeps profile
# env files authoritative.
# `PROFILE ?= baseline` above is the compose/profile default for capture and
# smoke-fh; for `make test` a PROFILE given by the user (command line or env)
# selects the suite profile, otherwise the recipe auto-detects default|baseline.
TEST_PROFILE :=
ifneq ($(filter command line environment,$(origin PROFILE)),)
  TEST_PROFILE := $(PROFILE)
endif

test:
	@test -n "$(SUITE)" || { echo "usage: make test SUITE=<suite> [PROFILE=<profile>]"; $(MAKE) --no-print-directory test-list; exit 2; }
	@test -x $(ROOT)/tests/$(SUITE)/run.sh || { echo "FAIL: unknown suite '$(SUITE)' (no tests/$(SUITE)/run.sh)"; exit 2; }
	@if [ -z "$(TEST_PROFILE)" ]; then \
	  if [ -d $(ROOT)/tests/$(SUITE)/profiles/default ]; then P=default; \
	  elif [ -d $(ROOT)/tests/$(SUITE)/profiles/baseline ]; then P=baseline; fi; \
	else P="$(TEST_PROFILE)"; fi; \
	[ -n "$${P:-}" ] || { echo "usage: make test SUITE=$(SUITE) PROFILE=<one of:$$(for p in $(ROOT)/tests/$(SUITE)/profiles/*/; do echo -n " $$(basename $$p)"; done)>"; exit 2; }; \
	echo "[test] SUITE=$(SUITE) PROFILE=$$P"; \
	env -i PATH="$(PATH)" HOME="$(HOME)" TERM="$(TERM)" LANG="$(LANG)" \
	  USER="$(USER)" LOGNAME="$(LOGNAME)" SHELL="$(SHELL)" TMPDIR="$${TMPDIR:-/tmp}" \
	  PROFILE=$$P $(ROOT)/tests/$(SUITE)/run.sh

$(foreach s,$(SUITES),test-$(s)):
	@$(MAKE) --no-print-directory test SUITE=$(patsubst test-%,%,$@)
