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
NPROBE_PAIRS=(${NPROBE_PAIRS:-240:240 16:24})

echo -e "run\tcandidates_target\thard_cap\tnprobe_primary\tnprobe_second_pass\tborderline_second_pass\tscore\tp99\tfailure_rate\thttp_errors\toom_killed\tstartup_badarg\texit_code" >"$OUT_FILE"

echo "== tune-loop =="
echo "OUT_FILE=$OUT_FILE"
echo "RPS=$RPS DURATION_SECONDS=$DURATION_SECONDS PRE_VUS=$PRE_VUS MAX_VUS=$MAX_VUS"
echo

run_one() {
  local target="$1"
  local hard_cap="$2"
  local nprobe_primary="$3"
  local nprobe_second_pass="$4"
  local skip_build="$5"

  local latest run_dir exit_code score p99 failure http_errors oom badarg

  set +e
  CANDIDATES_TARGET="$target" \
  CANDIDATES_HARD_CAP="$hard_cap" \
  NPROBE_PRIMARY="$nprobe_primary" \
  NPROBE_SECOND_PASS="$nprobe_second_pass" \
  BORDERLINE_SECOND_PASS_ENABLED="$([ "$nprobe_second_pass" -gt "$nprobe_primary" ] && echo 1 || echo 0)" \
  SKIP_BUILD="$skip_build" \
  K6_TARGET_RPS="$RPS" \
  K6_DURATION_SECONDS="$DURATION_SECONDS" \
  K6_PRE_ALLOCATED_VUS="$PRE_VUS" \
  K6_MAX_VUS="$MAX_VUS" \
  HTTP_TIMEOUT_MS="$TIMEOUT_MS" \
  make bench
  exit_code=$?
  set -e

  latest=$(find benchmarks -mindepth 1 -maxdepth 1 -type d -printf '%T@ %f\n' 2>/dev/null | sort -n | tail -n 1 | awk '{print $2}')
  run_dir="benchmarks/$latest"

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

  local second_pass_enabled
  if [ "$nprobe_second_pass" -gt "$nprobe_primary" ]; then
    second_pass_enabled="1"
  else
    second_pass_enabled="0"
  fi

  echo -e "${latest}\t${target}\t${hard_cap}\t${nprobe_primary}\t${nprobe_second_pass}\t${second_pass_enabled}\t${score}\t${p99}\t${failure}\t${http_errors}\t${oom}\t${badarg}\t${exit_code}" >>"$OUT_FILE"
  printf "run=%s target=%s hard_cap=%s nprobe=%s/%s second_pass=%s score=%s p99=%s fail=%s http=%s oom=%s badarg=%s exit=%s\n" \
    "$latest" "$target" "$hard_cap" "$nprobe_primary" "$nprobe_second_pass" "$second_pass_enabled" "$score" "$p99" "$failure" "$http_errors" "$oom" "$badarg" "$exit_code"
}

did_build=0
for pair in "${NPROBE_PAIRS[@]}"; do
  IFS=':' read -r nprobe_primary nprobe_second_pass <<<"$pair"

  for target in "${TARGETS[@]}"; do
    for hard_cap in "${HARD_CAPS[@]}"; do
      if [ "$hard_cap" -lt "$target" ]; then
        continue
      fi

      if [ "$did_build" -eq 0 ]; then
        run_one "$target" "$hard_cap" "$nprobe_primary" "$nprobe_second_pass" "0"
        did_build=1
      else
        run_one "$target" "$hard_cap" "$nprobe_primary" "$nprobe_second_pass" "1"
      fi
    done
  done
done

echo
echo "Top 5 (maior score):"
{
  read -r header
  echo "$header"
  sort -t $'\t' -k7,7nr "$OUT_FILE"
} <"$OUT_FILE" | head -n 6

echo
echo "Arquivo salvo: $OUT_FILE"
