#!/usr/bin/env bash
set -euo pipefail

OUT_DIR=${1:-benchmarks}

if [ ! -d "$OUT_DIR" ]; then
  echo "diretorio nao encontrado: $OUT_DIR" >&2
  exit 1
fi

printf "run\tscore\tp99\tfail_rate\thttp_errors\tdropped_iterations\toom_killed\tstartup_badarg\tno_live_upstreams\texit1\n"

for d in $(ls -1 "$OUT_DIR" | sort); do
  run_dir="$OUT_DIR/$d"

  score="-"
  p99="-"
  fail_rate="-"
  http_errors="-"
  dropped_iterations="-"
  oom_killed="no"
  startup_badarg="no"
  no_live_upstreams="no"
  exit1="no"

  if [ -f "$run_dir/results.json" ]; then
    score=$(jq -r '.scoring.final_score // "-"' "$run_dir/results.json")
    p99=$(jq -r '.p99 // "-"' "$run_dir/results.json")
    fail_rate=$(jq -r '.scoring.failure_rate // "-"' "$run_dir/results.json")
    http_errors=$(jq -r '.scoring.breakdown.http_errors // "-"' "$run_dir/results.json")
  fi

  if [ -f "$run_dir/k6-summary.json" ]; then
    dropped_iterations=$(jq -r '.metrics.dropped_iterations.values.count // 0' "$run_dir/k6-summary.json")
  fi

  if [ -f "$run_dir/container-state.txt" ] && awk -F'|' 'NR > 1 && $7 == "true" { found=1 } END { exit(found ? 0 : 1) }' "$run_dir/container-state.txt"; then
    oom_killed="yes"
  fi

  if [ -f "$run_dir/container-state.txt" ] && rg -n '\|exited\|false\|1\|' "$run_dir/container-state.txt" >/dev/null; then
    exit1="yes"
  fi

  if [ -f "$run_dir/docker-compose.logs.txt" ] && rg -n 'ranch_acceptors_sup|badarg' "$run_dir/docker-compose.logs.txt" >/dev/null; then
    startup_badarg="yes"
  fi

  if [ -f "$run_dir/docker-compose.logs.txt" ] && rg -n 'no live upstreams' "$run_dir/docker-compose.logs.txt" >/dev/null; then
    no_live_upstreams="yes"
  fi

  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$d" "$score" "$p99" "$fail_rate" "$http_errors" "$dropped_iterations" "$oom_killed" "$startup_badarg" "$no_live_upstreams" "$exit1"
done
