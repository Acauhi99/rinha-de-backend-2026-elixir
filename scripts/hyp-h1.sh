#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_URL="${REPO_URL:-https://github.com/Acauhi99/rinha-de-backend-2026-elixir.git}"
BASE_REF="${BASE_REF:-origin/submission}"
H1_REF="${H1_REF:-}"
WORK_REPO_DIR="${WORK_REPO_DIR:-$ROOT_DIR/run/hyp-h1/repo}"
WORK_DIR="${WORK_DIR:-$ROOT_DIR/run/hyp-h1/work}"
RUNS_DIR="${RUNS_DIR:-$ROOT_DIR/benchmarks}"
K6_SCRIPT="${K6_SCRIPT:-$ROOT_DIR/test/test.js}"
K6_SUMMARY_MODE="${K6_SUMMARY_MODE:-full}"
K6_TARGET_RPS="${K6_TARGET_RPS:-450}"
K6_DURATION_SECONDS="${K6_DURATION_SECONDS:-45}"
RUNS_PER_VARIANT="${RUNS_PER_VARIANT:-2}"
INTERVAL_SECONDS="${INTERVAL_SECONDS:-60}"
PULL_IMAGES="${PULL_IMAGES:-1}"
KEEP_UP="${KEEP_UP:-0}"

SUITE_ID="$(date +"%Y%m%d-%H%M%S")"
SUITE_DIR="$RUNS_DIR/h1-suite-$SUITE_ID"
SUMMARY_FILE="$SUITE_DIR/summary.md"

CONTROL_DIR="$WORK_DIR/control"
H1_DIR="$WORK_DIR/h1"
RESOLVED_BASE_REF=""
RESOLVED_H1_REF=""

mkdir -p "$SUITE_DIR"

log() {
  printf "%s\t%s\n" "$(date -Iseconds)" "$*"
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "erro: comando '$cmd' nao encontrado" >&2
    exit 1
  fi
}

prepare_repo() {
  mkdir -p "$(dirname "$WORK_REPO_DIR")"

  if [ ! -d "$WORK_REPO_DIR/.git" ]; then
    log "clone repo -> $WORK_REPO_DIR"
    git clone "$REPO_URL" "$WORK_REPO_DIR" >/dev/null
  fi

  log "fetch repo"
  git -C "$WORK_REPO_DIR" fetch --force --prune origin >/dev/null
}

resolve_ref() {
  local ref="$1"

  if git -C "$WORK_REPO_DIR" rev-parse --verify "$ref^{commit}" >/dev/null 2>&1; then
    echo "$ref"
    return 0
  fi

  if git -C "$WORK_REPO_DIR" rev-parse --verify "origin/$ref^{commit}" >/dev/null 2>&1; then
    echo "origin/$ref"
    return 0
  fi

  echo "erro: ref invalida '$ref'" >&2
  exit 1
}

materialize_ref() {
  local ref="$1"
  local target_dir="$2"

  rm -rf "$target_dir"
  mkdir -p "$target_dir"

  git -C "$WORK_REPO_DIR" archive "$ref" | tar -x -C "$target_dir"
}

patch_h1_nginx() {
  local nginx_file="$1"
  local tmp_file
  tmp_file="$(mktemp)"

  if ! awk '
    BEGIN { in_block = 0; patched = 0 }
    {
      if ($0 ~ /location = \/fraud-score[[:space:]]*\{/) in_block = 1
      if (in_block && $0 ~ /proxy_next_upstream_tries[[:space:]]+2;/) {
        sub(/2;/, "1;")
        patched = 1
      }
      print
      if (in_block && $0 ~ /^[[:space:]]*}/) in_block = 0
    }
    END { if (!patched) exit 2 }
  ' "$nginx_file" >"$tmp_file"; then
    rm -f "$tmp_file"
    echo "erro: patch H1 nao aplicado em $nginx_file" >&2
    exit 1
  fi

  mv "$tmp_file" "$nginx_file"
}

wait_ready() {
  for _ in $(seq 1 120); do
    if curl -fsS http://localhost:9999/ready >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  echo "erro: timeout /ready em :9999" >&2
  return 1
}

collect_artifacts() {
  local run_dir="$1"
  local compose_project="$2"
  local compose_file="$3"

  docker compose -p "$compose_project" -f "$compose_file" ps --all >"$run_dir/docker-compose.ps.txt" || true
  docker compose -p "$compose_project" -f "$compose_file" logs >"$run_dir/docker-compose.logs.txt" || true
  docker stats --no-stream >"$run_dir/docker-stats.txt" || true

  : >"$run_dir/container-state.txt"
  echo "service|id|name|status|running|exit_code|oom_killed|restart_count|error|started_at|finished_at" >>"$run_dir/container-state.txt"

  for service in lb api01 api02 engine; do
    local id
    id="$(docker compose -p "$compose_project" -f "$compose_file" ps --all -q "$service" 2>/dev/null || true)"
    if [ -z "$id" ]; then
      continue
    fi

    docker inspect "$id" --format '{{json .}}' >"$run_dir/${service}-inspect.json" || true
    docker inspect "$id" \
      --format "$service|{{.Id}}|{{.Name}}|{{.State.Status}}|{{.State.Running}}|{{.State.ExitCode}}|{{.State.OOMKilled}}|{{.RestartCount}}|{{.State.Error}}|{{.State.StartedAt}}|{{.State.FinishedAt}}" \
      >>"$run_dir/container-state.txt" || true
  done
}

run_variant_once() {
  local variant="$1"
  local run_idx="$2"
  local variant_dir="$3"
  local pulled_flag_file="$4"

  local run_stamp
  run_stamp="$(date +"%Y%m%d-%H%M%S")"
  local run_dir="$RUNS_DIR/h1-${variant}-${run_idx}-${run_stamp}"
  local compose_file="$variant_dir/docker-compose.yml"
  local compose_project="h1-${variant}-${run_idx}-${run_stamp}"
  local events_file="$run_dir/events.log"

  mkdir -p "$run_dir"

  {
    echo "variant=$variant"
    echo "run_idx=$run_idx"
    echo "suite_id=$SUITE_ID"
    echo "repo_url=$REPO_URL"
    echo "base_ref=$BASE_REF"
    if [ -n "$H1_REF" ]; then
      echo "h1_ref=$H1_REF"
    fi
    echo "k6_target_rps=$K6_TARGET_RPS"
    echo "k6_duration_seconds=$K6_DURATION_SECONDS"
  } >"$run_dir/run-meta.txt"

  printf "%s\t%s\n" "$(date -Iseconds)" "compose down stale" >>"$events_file"
  docker compose -p "$compose_project" -f "$compose_file" down --remove-orphans >/dev/null 2>&1 || true

  if [ "$PULL_IMAGES" = "1" ] && [ ! -f "$pulled_flag_file" ]; then
    printf "%s\t%s\n" "$(date -Iseconds)" "compose pull" >>"$events_file"
    docker compose -p "$compose_project" -f "$compose_file" pull >>"$events_file" 2>&1
    touch "$pulled_flag_file"
  fi

  printf "%s\t%s\n" "$(date -Iseconds)" "compose up" >>"$events_file"
  docker compose -p "$compose_project" -f "$compose_file" up -d >>"$events_file" 2>&1

  printf "%s\t%s\n" "$(date -Iseconds)" "wait ready" >>"$events_file"
  wait_ready

  printf "%s\t%s\n" "$(date -Iseconds)" "k6 run" >>"$events_file"
  (
    cd "$ROOT_DIR"
    export K6_NO_USAGE_REPORT=true
    export K6_TARGET_RPS
    export K6_DURATION_SECONDS
    k6 run --summary-mode "$K6_SUMMARY_MODE" --summary-export "$run_dir/k6-summary.json" "$K6_SCRIPT" | tee "$run_dir/k6-output.txt" >&2
    cp "$ROOT_DIR/test/results.json" "$run_dir/results.json"
  )

  printf "%s\t%s\n" "$(date -Iseconds)" "collect artifacts" >>"$events_file"
  collect_artifacts "$run_dir" "$compose_project" "$compose_file"

  if [ "$KEEP_UP" != "1" ]; then
    printf "%s\t%s\n" "$(date -Iseconds)" "compose down" >>"$events_file"
    docker compose -p "$compose_project" -f "$compose_file" down --remove-orphans >/dev/null 2>&1 || true
  fi

  echo "$run_dir"
}

extract_metric() {
  local json_file="$1"
  local jq_expr="$2"
  jq -r "$jq_expr" "$json_file"
}

p99_to_float() {
  local p99="$1"
  printf "%s" "$p99" | tr -d 'ms'
}

evaluate_gates() {
  local control1="$1"
  local control2="$2"
  local h1_1="$3"
  local h1_2="$4"

  local c1_http c2_http h1a_http h1b_http
  local c1_p99 c2_p99 h1a_p99 h1b_p99
  local c1_final c2_final h1a_final h1b_final

  c1_http="$(extract_metric "$control1/results.json" '.scoring.breakdown.http_errors')"
  c2_http="$(extract_metric "$control2/results.json" '.scoring.breakdown.http_errors')"
  h1a_http="$(extract_metric "$h1_1/results.json" '.scoring.breakdown.http_errors')"
  h1b_http="$(extract_metric "$h1_2/results.json" '.scoring.breakdown.http_errors')"

  c1_p99="$(p99_to_float "$(extract_metric "$control1/results.json" '.p99')")"
  c2_p99="$(p99_to_float "$(extract_metric "$control2/results.json" '.p99')")"
  h1a_p99="$(p99_to_float "$(extract_metric "$h1_1/results.json" '.p99')")"
  h1b_p99="$(p99_to_float "$(extract_metric "$h1_2/results.json" '.p99')")"

  c1_final="$(extract_metric "$control1/results.json" '.scoring.final_score')"
  c2_final="$(extract_metric "$control2/results.json" '.scoring.final_score')"
  h1a_final="$(extract_metric "$h1_1/results.json" '.scoring.final_score')"
  h1b_final="$(extract_metric "$h1_2/results.json" '.scoring.final_score')"

  local gate_http gate_p99 gate_final
  gate_http="false"
  gate_p99="false"
  gate_final="false"

  if [ "$h1a_http" -lt "$c1_http" ] && [ "$h1b_http" -lt "$c2_http" ]; then
    gate_http="true"
  fi

  if awk -v c1="$c1_p99" -v h1a="$h1a_p99" -v c2="$c2_p99" -v h1b="$h1b_p99" 'BEGIN { ok1=(h1a <= c1*1.05); ok2=(h1b <= c2*1.05); exit(!(ok1&&ok2)); }'; then
    gate_p99="true"
  fi

  if awk -v c1="$c1_final" -v c2="$c2_final" -v h1a="$h1a_final" -v h1b="$h1b_final" 'BEGIN { c=(c1+c2)/2.0; h=(h1a+h1b)/2.0; exit(!(h >= c + 100.0)); }'; then
    gate_final="true"
  fi

  {
    echo ""
    echo "## Gate Check"
    echo ""
    echo "- gate_http_errors: $gate_http"
    echo "- gate_p99_5pct: $gate_p99"
    echo "- gate_final_score_plus_100_avg: $gate_final"

    if [ "$gate_http" = "true" ] && [ "$gate_p99" = "true" ] && [ "$gate_final" = "true" ]; then
      echo "- promote_to_full: true"
    else
      echo "- promote_to_full: false"
    fi
  } >>"$SUMMARY_FILE"
}

write_summary_header() {
  {
    echo "# H1 Summary"
    echo ""
    echo "- suite_id: $SUITE_ID"
    echo "- repo_url: $REPO_URL"
    echo "- base_ref: ${RESOLVED_BASE_REF:-$BASE_REF}"
    if [ -n "$H1_REF" ]; then
      echo "- h1_ref: ${RESOLVED_H1_REF:-$H1_REF}"
    else
      echo "- h1_ref: (patch local em nginx.conf: proxy_next_upstream_tries 2->1 em /fraud-score)"
    fi
    echo "- k6_target_rps: $K6_TARGET_RPS"
    echo "- k6_duration_seconds: $K6_DURATION_SECONDS"
    echo ""
    echo "## Runs"
    echo ""
    echo "| variant | run | final_score | p99 | failure_rate | http_errors | run_dir |"
    echo "|---|---:|---:|---:|---:|---:|---|"
  } >"$SUMMARY_FILE"
}

append_run_summary() {
  local variant="$1"
  local run_idx="$2"
  local run_dir="$3"

  local results_file="$run_dir/results.json"
  local final_score p99 failure_rate http_errors

  final_score="$(extract_metric "$results_file" '.scoring.final_score')"
  p99="$(extract_metric "$results_file" '.p99')"
  failure_rate="$(extract_metric "$results_file" '.scoring.failure_rate')"
  http_errors="$(extract_metric "$results_file" '.scoring.breakdown.http_errors')"

  echo "| $variant | $run_idx | $final_score | $p99 | $failure_rate | $http_errors | $run_dir |" >>"$SUMMARY_FILE"
}

main() {
  require_cmd git
  require_cmd docker
  require_cmd curl
  require_cmd jq
  require_cmd rg
  require_cmd k6

  if [ "$RUNS_PER_VARIANT" -ne 2 ]; then
    echo "erro: RUNS_PER_VARIANT precisa ser 2 para os gates atuais" >&2
    exit 1
  fi

  prepare_repo

  rm -rf "$WORK_DIR"
  mkdir -p "$WORK_DIR"

  local resolved_base_ref
  local resolved_h1_ref

  resolved_base_ref="$(resolve_ref "$BASE_REF")"
  RESOLVED_BASE_REF="$resolved_base_ref"
  log "materialize control ref: $RESOLVED_BASE_REF"
  materialize_ref "$RESOLVED_BASE_REF" "$CONTROL_DIR"

  if [ -n "$H1_REF" ]; then
    resolved_h1_ref="$(resolve_ref "$H1_REF")"
    RESOLVED_H1_REF="$resolved_h1_ref"
    log "materialize h1 ref: $RESOLVED_H1_REF"
    materialize_ref "$RESOLVED_H1_REF" "$H1_DIR"
  else
    log "materialize h1 via patch local"
    cp -a "$CONTROL_DIR/." "$H1_DIR/"
    patch_h1_nginx "$H1_DIR/nginx.conf"
  fi

  write_summary_header

  local pull_marker="$SUITE_DIR/.images_pulled"
  local control_run1 control_run2 h1_run1 h1_run2

  log "run control #1"
  control_run1="$(run_variant_once "control" 1 "$CONTROL_DIR" "$pull_marker")"
  append_run_summary "control" 1 "$control_run1"
  sleep "$INTERVAL_SECONDS"

  log "run control #2"
  control_run2="$(run_variant_once "control" 2 "$CONTROL_DIR" "$pull_marker")"
  append_run_summary "control" 2 "$control_run2"
  sleep "$INTERVAL_SECONDS"

  log "run h1 #1"
  h1_run1="$(run_variant_once "h1" 1 "$H1_DIR" "$pull_marker")"
  append_run_summary "h1" 1 "$h1_run1"
  sleep "$INTERVAL_SECONDS"

  log "run h1 #2"
  h1_run2="$(run_variant_once "h1" 2 "$H1_DIR" "$pull_marker")"
  append_run_summary "h1" 2 "$h1_run2"

  evaluate_gates "$control_run1" "$control_run2" "$h1_run1" "$h1_run2"

  log "done summary=$SUMMARY_FILE"
  cat "$SUMMARY_FILE"
}

main "$@"
