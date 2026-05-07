#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_REF="${BASE_REF:-submission-hyp-h2}"
FALLBACK_BASE_REF="${FALLBACK_BASE_REF:-submission}"
COMPOSE_FILE_NAME="${COMPOSE_FILE_NAME:-docker-compose.local.yml}"
WORK_DIR="${WORK_DIR:-$ROOT_DIR/run/hyp-h2/work}"
RUNS_DIR="${RUNS_DIR:-$ROOT_DIR/benchmarks}"
K6_SCRIPT="${K6_SCRIPT:-$ROOT_DIR/test/test.js}"
K6_SUMMARY_MODE="${K6_SUMMARY_MODE:-full}"
SHORT_K6_TARGET_RPS="${SHORT_K6_TARGET_RPS:-450}"
SHORT_K6_DURATION_SECONDS="${SHORT_K6_DURATION_SECONDS:-45}"
FULL_K6_TARGET_RPS="${FULL_K6_TARGET_RPS:-900}"
FULL_K6_DURATION_SECONDS="${FULL_K6_DURATION_SECONDS:-120}"
TARGETS="${TARGETS:-1000 1200 1400 1600}"
HARD_CAP="${HARD_CAP:-2000}"
RUNS_PER_TARGET="${RUNS_PER_TARGET:-2}"
INTERVAL_SECONDS="${INTERVAL_SECONDS:-60}"
PULL_IMAGES="${PULL_IMAGES:-1}"
KEEP_UP="${KEEP_UP:-0}"

SUITE_ID="$(date +"%Y%m%d-%H%M%S")"
SUITE_DIR="$RUNS_DIR/h2-suite-$SUITE_ID"
SUMMARY_FILE="$SUITE_DIR/summary.md"
RESOLVED_BASE_REF=""

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

resolve_ref_with_fallback() {
  if git -C "$ROOT_DIR" rev-parse --verify "$BASE_REF^{commit}" >/dev/null 2>&1; then
    echo "$BASE_REF"
    return 0
  fi

  if git -C "$ROOT_DIR" rev-parse --verify "$FALLBACK_BASE_REF^{commit}" >/dev/null 2>&1; then
    log "base_ref '$BASE_REF' ausente; fallback -> '$FALLBACK_BASE_REF'"
    echo "$FALLBACK_BASE_REF"
    return 0
  fi

  echo "erro: refs invalidas BASE_REF='$BASE_REF' FALLBACK_BASE_REF='$FALLBACK_BASE_REF'" >&2
  exit 1
}

materialize_ref() {
  local ref="$1"
  local target_dir="$2"
  rm -rf "$target_dir"
  mkdir -p "$target_dir"
  git -C "$ROOT_DIR" archive "$ref" | tar -x -C "$target_dir"
}

patch_compose_candidate_knobs() {
  local compose_file="$1"
  local target="$2"
  local hard_cap="$3"
  local tmp_file
  tmp_file="$(mktemp)"

  awk -v target="$target" -v hard_cap="$hard_cap" '
    {
      line = $0

      if (line ~ /CANDIDATES_TARGET:/) {
        sub(/:.*/, ": \"" target "\"", line)
      }

      if (line ~ /CANDIDATES_HARD_CAP:/) {
        sub(/:.*/, ": \"" hard_cap "\"", line)
      }

      print line
    }
  ' "$compose_file" >"$tmp_file"

  mv "$tmp_file" "$compose_file"
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

extract_metric() {
  local json_file="$1"
  local jq_expr="$2"
  jq -r "$jq_expr" "$json_file"
}

p99_to_float() {
  local p99="$1"
  printf "%s" "$p99" | tr -d 'ms'
}

oom_killed_flag() {
  local run_dir="$1"
  if [ -f "$run_dir/container-state.txt" ] && awk -F'|' 'NR > 1 && $7 == "true" { found=1 } END { exit(found ? 0 : 1) }' "$run_dir/container-state.txt"; then
    echo "yes"
  else
    echo "no"
  fi
}

run_variant_once() {
  local label="$1"
  local run_idx="$2"
  local variant_dir="$3"
  local mode="$4"
  local pulled_flag_file="$5"
  local target="$6"
  local hard_cap="$7"

  local run_stamp
  run_stamp="$(date +"%Y%m%d-%H%M%S")"
  local run_dir="$RUNS_DIR/h2-${label}-${mode}-${run_idx}-${run_stamp}"
  local compose_file="$variant_dir/$COMPOSE_FILE_NAME"
  local compose_project="h2-${mode}-${label}-${run_idx}-${run_stamp}"
  local events_file="$run_dir/events.log"
  local mode_rps mode_duration

  if [ "$mode" = "short" ]; then
    mode_rps="$SHORT_K6_TARGET_RPS"
    mode_duration="$SHORT_K6_DURATION_SECONDS"
  else
    mode_rps="$FULL_K6_TARGET_RPS"
    mode_duration="$FULL_K6_DURATION_SECONDS"
  fi

  mkdir -p "$run_dir"

  if [ ! -f "$compose_file" ]; then
    echo "erro: compose '$compose_file' nao encontrado" >&2
    exit 1
  fi

  {
    echo "suite_id=$SUITE_ID"
    echo "mode=$mode"
    echo "label=$label"
    echo "run_idx=$run_idx"
    echo "target=$target"
    echo "hard_cap=$hard_cap"
    echo "k6_target_rps=$mode_rps"
    echo "k6_duration_seconds=$mode_duration"
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
    export K6_TARGET_RPS="$mode_rps"
    export K6_DURATION_SECONDS="$mode_duration"
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

append_run_summary() {
  local label="$1"
  local mode="$2"
  local run_idx="$3"
  local target="$4"
  local hard_cap="$5"
  local run_dir="$6"
  local results_file="$run_dir/results.json"
  local final_score p99 failure_rate http_errors fn fp score_det dropped oom

  final_score="$(extract_metric "$results_file" '.scoring.final_score')"
  p99="$(extract_metric "$results_file" '.p99')"
  failure_rate="$(extract_metric "$results_file" '.scoring.failure_rate')"
  http_errors="$(extract_metric "$results_file" '.scoring.breakdown.http_errors')"
  fn="$(extract_metric "$results_file" '.scoring.breakdown.false_negative_detections')"
  fp="$(extract_metric "$results_file" '.scoring.breakdown.false_positive_detections')"
  score_det="$(extract_metric "$results_file" '.scoring.detection_score.value')"
  dropped="$(extract_metric "$run_dir/k6-summary.json" '.metrics.dropped_iterations.values.count // 0')"
  oom="$(oom_killed_flag "$run_dir")"

  echo "| $mode | $label | $run_idx | $target | $hard_cap | $final_score | $score_det | $p99 | $failure_rate | $fn | $fp | $http_errors | $dropped | $oom | $run_dir |" >>"$SUMMARY_FILE"
}

avg_metric() {
  local r1="$1"
  local r2="$2"
  local jq_expr="$3"
  awk -v a="$(extract_metric "$r1/results.json" "$jq_expr")" -v b="$(extract_metric "$r2/results.json" "$jq_expr")" 'BEGIN { printf "%.6f", (a + b) / 2.0 }'
}

avg_p99_metric() {
  local r1="$1"
  local r2="$2"
  awk -v a="$(p99_to_float "$(extract_metric "$r1/results.json" '.p99')")" -v b="$(p99_to_float "$(extract_metric "$r2/results.json" '.p99')")" 'BEGIN { printf "%.6f", (a + b) / 2.0 }'
}

short_gate_and_pick_winner() {
  local control_r1="$1"
  local control_r2="$2"
  shift 2
  local records=("$@")

  local control_fn_avg control_det_avg control_p99_avg
  control_fn_avg="$(avg_metric "$control_r1" "$control_r2" '.scoring.breakdown.false_negative_detections')"
  control_det_avg="$(avg_metric "$control_r1" "$control_r2" '.scoring.detection_score.value')"
  control_p99_avg="$(avg_p99_metric "$control_r1" "$control_r2")"

  {
    echo ""
    echo "## H2 Criteria (Short)"
    echo ""
    echo "- fn_drop_target: >=8%"
    echo "- score_det_gain_target: >=+120"
    echo "- p99_regression_limit: <=5%"
    echo "- http_errors: 0"
    echo ""
    echo "| label | fn_avg | fn_drop_pct | score_det_avg | score_det_gain | p99_avg_ms | p99_reg_pct | http_errors_sum | pass |"
    echo "|---|---:|---:|---:|---:|---:|---:|---:|---|"
  } >>"$SUMMARY_FILE"

  local winner_label=""
  local winner_target=""
  local winner_dir=""
  local winner_final_avg=""
  local winner_p99_avg=""
  local winner_fn_avg=""
  local winner_passed="false"

  local fallback_label=""
  local fallback_target=""
  local fallback_dir=""
  local fallback_final_avg="-1.0e99"
  local fallback_p99_avg=""
  local fallback_fn_avg=""

  for record in "${records[@]}"; do
    IFS='|' read -r label target run1 run2 variant_dir <<<"$record"

    local fn_avg det_avg p99_avg final_avg http_sum
    fn_avg="$(avg_metric "$run1" "$run2" '.scoring.breakdown.false_negative_detections')"
    det_avg="$(avg_metric "$run1" "$run2" '.scoring.detection_score.value')"
    p99_avg="$(avg_p99_metric "$run1" "$run2")"
    final_avg="$(avg_metric "$run1" "$run2" '.scoring.final_score')"
    http_sum="$(awk -v a="$(extract_metric "$run1/results.json" '.scoring.breakdown.http_errors')" -v b="$(extract_metric "$run2/results.json" '.scoring.breakdown.http_errors')" 'BEGIN { printf "%.0f", a + b }')"

    local fn_drop_pct det_gain p99_reg_pct pass
    fn_drop_pct="$(awk -v c="$control_fn_avg" -v t="$fn_avg" 'BEGIN { if (c == 0) { print 0 } else { printf "%.4f", ((c - t) / c) * 100.0 } }')"
    det_gain="$(awk -v c="$control_det_avg" -v t="$det_avg" 'BEGIN { printf "%.4f", t - c }')"
    p99_reg_pct="$(awk -v c="$control_p99_avg" -v t="$p99_avg" 'BEGIN { if (c == 0) { print 0 } else { printf "%.4f", ((t - c) / c) * 100.0 } }')"
    pass="false"

    if awk -v fn_drop="$fn_drop_pct" -v det_gain="$det_gain" -v p99_reg="$p99_reg_pct" -v http_sum="$http_sum" \
      'BEGIN { ok = (fn_drop >= 8.0) && (det_gain >= 120.0) && (p99_reg <= 5.0) && (http_sum == 0); exit(!ok) }'; then
      pass="true"
    fi

    echo "| $label | $fn_avg | $fn_drop_pct% | $det_avg | $det_gain | $p99_avg | $p99_reg_pct% | $http_sum | $pass |" >>"$SUMMARY_FILE"

    if [ "$label" != "control" ]; then
      if awk -v curr="$final_avg" -v best="$fallback_final_avg" -v curr_p99="$p99_avg" -v best_p99="${fallback_p99_avg:-1.0e99}" -v curr_fn="$fn_avg" -v best_fn="${fallback_fn_avg:-1.0e99}" \
        'BEGIN {
          if (curr > best) exit(0);
          if (curr < best) exit(1);
          if (curr_p99 < best_p99) exit(0);
          if (curr_p99 > best_p99) exit(1);
          if (curr_fn < best_fn) exit(0);
          exit(1);
        }'; then
        fallback_label="$label"
        fallback_target="$target"
        fallback_dir="$variant_dir"
        fallback_final_avg="$final_avg"
        fallback_p99_avg="$p99_avg"
        fallback_fn_avg="$fn_avg"
      fi
    fi

    if [ "$pass" = "true" ]; then
      if [ "$winner_label" = "" ] || awk -v curr="$final_avg" -v best="$winner_final_avg" -v curr_p99="$p99_avg" -v best_p99="$winner_p99_avg" -v curr_fn="$fn_avg" -v best_fn="$winner_fn_avg" \
        'BEGIN {
          if (curr > best) exit(0);
          if (curr < best) exit(1);
          if (curr_p99 < best_p99) exit(0);
          if (curr_p99 > best_p99) exit(1);
          if (curr_fn < best_fn) exit(0);
          exit(1);
        }'; then
        winner_label="$label"
        winner_target="$target"
        winner_dir="$variant_dir"
        winner_final_avg="$final_avg"
        winner_p99_avg="$p99_avg"
        winner_fn_avg="$fn_avg"
        winner_passed="true"
      fi
    fi
  done

  if [ "$winner_label" = "" ]; then
    winner_label="$fallback_label"
    winner_target="$fallback_target"
    winner_dir="$fallback_dir"
    winner_final_avg="$fallback_final_avg"
    winner_p99_avg="$fallback_p99_avg"
    winner_fn_avg="$fallback_fn_avg"
    winner_passed="false"
  fi

  {
    echo ""
    echo "## Short Winner"
    echo ""
    if [ "$winner_passed" = "true" ]; then
      echo "- winner_type: passed_criteria"
    else
      echo "- winner_type: fallback_best_final_score"
    fi
    echo "- winner_label: $winner_label"
    echo "- winner_target: $winner_target"
    echo "- winner_final_score_avg: $winner_final_avg"
    echo "- winner_p99_avg_ms: $winner_p99_avg"
    echo "- winner_fn_avg: $winner_fn_avg"
  } >>"$SUMMARY_FILE"

  printf "%s|%s|%s|%s\n" "$winner_label" "$winner_target" "$winner_dir" "$winner_passed"
}

write_summary_header() {
  {
    echo "# H2 Summary"
    echo ""
    echo "- suite_id: $SUITE_ID"
    echo "- base_ref: ${RESOLVED_BASE_REF:-$BASE_REF}"
    echo "- compose_file: $COMPOSE_FILE_NAME"
    echo "- targets: $TARGETS"
    echo "- hard_cap: $HARD_CAP"
    echo "- short_profile: rps=$SHORT_K6_TARGET_RPS duration=${SHORT_K6_DURATION_SECONDS}s"
    echo "- full_profile: rps=$FULL_K6_TARGET_RPS duration=${FULL_K6_DURATION_SECONDS}s"
    echo "- runs_per_target: $RUNS_PER_TARGET"
    echo ""
    echo "## Runs"
    echo ""
    echo "| mode | label | run | target | hard_cap | final_score | score_det | p99 | failure_rate | fn | fp | http_errors | dropped_iters | oom_killed | run_dir |"
    echo "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---|"
  } >"$SUMMARY_FILE"
}

write_full_runs_header() {
  {
    echo ""
    echo "## Full Runs"
    echo ""
    echo "| mode | label | run | target | hard_cap | final_score | score_det | p99 | failure_rate | fn | fp | http_errors | dropped_iters | oom_killed | run_dir |"
    echo "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---|"
  } >>"$SUMMARY_FILE"
}

main() {
  require_cmd git
  require_cmd docker
  require_cmd curl
  require_cmd jq
  require_cmd awk
  require_cmd k6

  if [ "$RUNS_PER_TARGET" -ne 2 ]; then
    echo "erro: RUNS_PER_TARGET precisa ser 2" >&2
    exit 1
  fi

  rm -rf "$WORK_DIR"
  mkdir -p "$WORK_DIR"

  local resolved_base_ref
  resolved_base_ref="$(resolve_ref_with_fallback)"
  RESOLVED_BASE_REF="$resolved_base_ref"
  log "materialize base ref: $RESOLVED_BASE_REF"

  local targets_arr
  read -r -a targets_arr <<<"$TARGETS"

  if [ "${#targets_arr[@]}" -lt 2 ]; then
    echo "erro: TARGETS precisa ter pelo menos control + 1 variante" >&2
    exit 1
  fi

  local pull_marker="$SUITE_DIR/.images_pulled"
  local variant_records=()

  write_summary_header

  for target in "${targets_arr[@]}"; do
    local label="t${target}"
    if [ "$target" = "1000" ]; then
      label="control"
    fi

    local variant_dir="$WORK_DIR/$label"
    materialize_ref "$RESOLVED_BASE_REF" "$variant_dir"
    patch_compose_candidate_knobs "$variant_dir/$COMPOSE_FILE_NAME" "$target" "$HARD_CAP"

    local run1 run2
    log "run short $label #1 target=$target hard_cap=$HARD_CAP"
    run1="$(run_variant_once "$label" 1 "$variant_dir" "short" "$pull_marker" "$target" "$HARD_CAP")"
    append_run_summary "$label" "short" 1 "$target" "$HARD_CAP" "$run1"
    sleep "$INTERVAL_SECONDS"

    log "run short $label #2 target=$target hard_cap=$HARD_CAP"
    run2="$(run_variant_once "$label" 2 "$variant_dir" "short" "$pull_marker" "$target" "$HARD_CAP")"
    append_run_summary "$label" "short" 2 "$target" "$HARD_CAP" "$run2"

    variant_records+=("$label|$target|$run1|$run2|$variant_dir")

    sleep "$INTERVAL_SECONDS"
  done

  local control_r1 control_r2
  control_r1=""
  control_r2=""
  for record in "${variant_records[@]}"; do
    IFS='|' read -r label _target run1 run2 _dir <<<"$record"
    if [ "$label" = "control" ]; then
      control_r1="$run1"
      control_r2="$run2"
      break
    fi
  done

  if [ -z "$control_r1" ] || [ -z "$control_r2" ]; then
    echo "erro: control target=1000 ausente em TARGETS" >&2
    exit 1
  fi

  local winner_info winner_label winner_target winner_dir winner_passed
  winner_info="$(short_gate_and_pick_winner "$control_r1" "$control_r2" "${variant_records[@]}")"
  IFS='|' read -r winner_label winner_target winner_dir winner_passed <<<"$winner_info"

  local full1 full2
  write_full_runs_header

  log "run full winner=$winner_label target=$winner_target #1"
  full1="$(run_variant_once "$winner_label" 1 "$winner_dir" "full" "$pull_marker" "$winner_target" "$HARD_CAP")"
  append_run_summary "$winner_label" "full" 1 "$winner_target" "$HARD_CAP" "$full1"
  sleep "$INTERVAL_SECONDS"

  log "run full winner=$winner_label target=$winner_target #2"
  full2="$(run_variant_once "$winner_label" 2 "$winner_dir" "full" "$pull_marker" "$winner_target" "$HARD_CAP")"
  append_run_summary "$winner_label" "full" 2 "$winner_target" "$HARD_CAP" "$full2"

  local full_final_avg full_det_avg full_p99_avg full_http_sum
  full_final_avg="$(avg_metric "$full1" "$full2" '.scoring.final_score')"
  full_det_avg="$(avg_metric "$full1" "$full2" '.scoring.detection_score.value')"
  full_p99_avg="$(avg_p99_metric "$full1" "$full2")"
  full_http_sum="$(awk -v a="$(extract_metric "$full1/results.json" '.scoring.breakdown.http_errors')" -v b="$(extract_metric "$full2/results.json" '.scoring.breakdown.http_errors')" 'BEGIN { printf "%.0f", a + b }')"

  {
    echo ""
    echo "## Full Validation (Winner)"
    echo ""
    echo "- winner_label: $winner_label"
    echo "- winner_target: $winner_target"
    echo "- winner_passed_short_criteria: $winner_passed"
    echo "- full_runs: 2"
    echo "- full_final_score_avg: $full_final_avg"
    echo "- full_score_det_avg: $full_det_avg"
    echo "- full_p99_avg_ms: $full_p99_avg"
    echo "- full_http_errors_sum: $full_http_sum"
    echo ""
    echo "Observacao: gate global completo exige baseline full comparavel em paralelo."
  } >>"$SUMMARY_FILE"

  log "done summary=$SUMMARY_FILE"
  cat "$SUMMARY_FILE"
}

main "$@"
