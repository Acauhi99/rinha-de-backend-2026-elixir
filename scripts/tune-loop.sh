#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT_DIR"

OUT_FILE=${OUT_FILE:-benchmarks/tune-loop-$(date +%Y%m%d-%H%M%S).tsv}
RPS=${RPS:-700}
DURATION_SECONDS=${DURATION_SECONDS:-45}
PRE_VUS=${PRE_VUS:-120}
MAX_VUS=${MAX_VUS:-280}
TIMEOUT_MS=${TIMEOUT_MS:-2001}

# Ordem importa: começa com opções mais conservadoras para evitar OOM cedo.
TARGETS=(${TARGETS:-700 900 1100 1300})
HARD_CAPS=(${HARD_CAPS:-1000 1400 1800 2200})

echo -e "run\tcandidates_target\thard_cap\tscore\tp99\tfailure_rate\thttp_errors\toom_killed\tstartup_badarg\texit_code" >"$OUT_FILE"

echo "== tune-loop =="
echo "OUT_FILE=$OUT_FILE"
echo "RPS=$RPS DURATION_SECONDS=$DURATION_SECONDS PRE_VUS=$PRE_VUS MAX_VUS=$MAX_VUS"
echo

run_one() {
  local target="$1"
  local hard_cap="$2"
  local skip_build="$3"

  local before after run_dir exit_code score p99 failure http_errors oom badarg
  before=$(find benchmarks -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort | tail -n 1 || true)

  set +e
  CANDIDATES_TARGET="$target" \
  CANDIDATES_HARD_CAP="$hard_cap" \
  SKIP_BUILD="$skip_build" \
  K6_TARGET_RPS="$RPS" \
  K6_DURATION_SECONDS="$DURATION_SECONDS" \
  K6_PRE_ALLOCATED_VUS="$PRE_VUS" \
  K6_MAX_VUS="$MAX_VUS" \
  HTTP_TIMEOUT_MS="$TIMEOUT_MS" \
  make bench
  exit_code=$?
  set -e

  after=$(find benchmarks -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort | tail -n 1 || true)
  run_dir="benchmarks/$after"

  score="-"
  p99="-"
  failure="-"
  http_errors="-"
  oom="no"
  badarg="no"

  if [ -f "$run_dir/results.json" ]; then
    score=$(jq -r '.scoring.final_score // "-"' "$run_dir/results.json")
    p99=$(jq -r '.p99 // "-"' "$run_dir/results.json")
    failure=$(jq -r '.scoring.failure_rate // "-"' "$run_dir/results.json")
    http_errors=$(jq -r '.scoring.breakdown.http_errors // "-"' "$run_dir/results.json")
  fi

  if [ -f "$run_dir/container-state.txt" ] && awk -F'|' 'NR > 1 && $7 == "true" { found=1 } END { exit(found ? 0 : 1) }' "$run_dir/container-state.txt"; then
    oom="yes"
  fi

  if [ -f "$run_dir/docker-compose.logs.txt" ] && rg -n 'ranch_acceptors_sup|badarg' "$run_dir/docker-compose.logs.txt" >/dev/null; then
    badarg="yes"
  fi

  echo -e "${after}\t${target}\t${hard_cap}\t${score}\t${p99}\t${failure}\t${http_errors}\t${oom}\t${badarg}\t${exit_code}" >>"$OUT_FILE"
  printf "run=%s target=%s hard_cap=%s score=%s p99=%s fail=%s http=%s oom=%s badarg=%s exit=%s\n" \
    "$after" "$target" "$hard_cap" "$score" "$p99" "$failure" "$http_errors" "$oom" "$badarg" "$exit_code"
}

did_build=0
for target in "${TARGETS[@]}"; do
  for hard_cap in "${HARD_CAPS[@]}"; do
    if [ "$hard_cap" -lt "$target" ]; then
      continue
    fi

    if [ "$did_build" -eq 0 ]; then
      run_one "$target" "$hard_cap" "0"
      did_build=1
    else
      run_one "$target" "$hard_cap" "1"
    fi
  done
done

echo
echo "Top 5 (maior score):"
{
  read -r header
  echo "$header"
  sort -t $'\t' -k4,4nr "$OUT_FILE"
} <"$OUT_FILE" | head -n 6

echo
echo "Arquivo salvo: $OUT_FILE"
