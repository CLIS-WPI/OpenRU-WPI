# Source after docker/bench.env, then call: radio_env_load <repo-root>
# Selects the bench radio with BENCH_RADIO=n310-10|n310-20|n310-30 (default n310-10) by overlaying
# docker/radios/<radio>.env. Values are exported, so they also win over `docker compose --env-file`.
# (RADIO already means uhd|null in up.sh/restart_ru.sh; the radio unit is BENCH_RADIO.)
radio_env_load() {
  local root="$1" f
  BENCH_RADIO="${BENCH_RADIO:-n310-10}"
  f="$root/docker/radios/$BENCH_RADIO.env"
  if [[ ! -f "$f" ]]; then
    echo "FAIL: unknown BENCH_RADIO=$BENCH_RADIO (have: $(cd "$root/docker/radios" && ls -- *.env | sed 's/\.env$//' | tr '\n' ' '))" >&2
    return 2
  fi
  set -a; . "$f"; set +a
  export BENCH_RADIO
}
