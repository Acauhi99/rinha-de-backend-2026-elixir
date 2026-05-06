#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_URL="${REPO_URL:-https://github.com/Acauhi99/rinha-de-backend-2026-elixir.git}"
SUBMISSION_REF="${SUBMISSION_REF:-87777994125510f5c37f1e6e3bac0f5532cc23ab}"
WORKTREE_DIR="${WORKTREE_DIR:-$ROOT_DIR/run/replay-8777799/repo}"
RUNS_DIR="${RUNS_DIR:-$ROOT_DIR/benchmarks}"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-rinha-replay-8777799}"
K6_SCRIPT="${K6_SCRIPT:-$ROOT_DIR/test/test.js}"
K6_SUMMARY_MODE="${K6_SUMMARY_MODE:-full}"
PULL_IMAGES="${PULL_IMAGES:-1}"
KEEP_UP="${KEEP_UP:-0}"

EXPECTED_FINAL_SCORE="${EXPECTED_FINAL_SCORE:--3606.02}"
EXPECTED_P99="${EXPECTED_P99:-2001.77ms}"
EXPECTED_FAILURE_RATE="${EXPECTED_FAILURE_RATE:-5.94%}"

RUN_ID="$(date +"%Y%m%d-%H%M%S")"
RUN_DIR="$RUNS_DIR/replay-8777799-$RUN_ID"
EVENTS_FILE="$RUN_DIR/events.log"
COMPOSE_FILE="$WORKTREE_DIR/docker-compose.yml"

mkdir -p "$RUN_DIR"

log() {
  printf "%s\t%s\n" "$(date -Iseconds)" "$*" | tee -a "$EVENTS_FILE"
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "erro: comando '$cmd' nao encontrado" >&2
    exit 1
  fi
}

update_submission_repo() {
  mkdir -p "$(dirname "$WORKTREE_DIR")"

  if [ ! -d "$WORKTREE_DIR/.git" ]; then
    log "clone submission repo -> $WORKTREE_DIR"
    git clone "$REPO_URL" "$WORKTREE_DIR" >/dev/null
  fi

  log "fetch repo"
  git -C "$WORKTREE_DIR" fetch --force --prune origin >/dev/null

  log "checkout ref $SUBMISSION_REF"
  git -C "$WORKTREE_DIR" checkout --detach "$SUBMISSION_REF" >/dev/null
  local resolved
  resolved="$(git -C "$WORKTREE_DIR" rev-parse HEAD)"
  log "repo commit resolved: $resolved"
}

verify_submission_shape() {
  [ -f "$COMPOSE_FILE" ] || { echo "erro: compose nao encontrado em $COMPOSE_FILE" >&2; exit 1; }
  [ -f "$WORKTREE_DIR/nginx.conf" ] || { echo "erro: nginx.conf nao encontrado em $WORKTREE_DIR" >&2; exit 1; }

  local digest_count
  digest_count="$(rg -c 'acauhi/rinha-2026-elixir@sha256:8e173a77be28a956eab4a483378669b49e05b1b51d036a558da4a063b635db9b' "$COMPOSE_FILE" || true)"
  if [ "$digest_count" -lt 2 ]; then
    echo "erro: imagem digest esperada nao encontrada 2x no compose" >&2
    exit 1
  fi

  rg -q 'cpus:[[:space:]]*"0.10"' "$COMPOSE_FILE" || { echo "erro: limite lb cpu 0.10 ausente" >&2; exit 1; }
  rg -q 'memory:[[:space:]]*10MB' "$COMPOSE_FILE" || { echo "erro: limite lb memoria 10MB ausente" >&2; exit 1; }
  rg -q 'cpus:[[:space:]]*"0.45"' "$COMPOSE_FILE" || { echo "erro: limite api cpu 0.45 ausente" >&2; exit 1; }
  rg -q 'memory:[[:space:]]*170MB' "$COMPOSE_FILE" || { echo "erro: limite api memoria 170MB ausente" >&2; exit 1; }

  log "compose verificado: digest + limites batem com preview"
}

wait_ready() {
  log "wait /ready"
  for _ in $(seq 1 120); do
    if curl -fsS http://localhost:9999/ready >/dev/null 2>&1; then
      log "ready ok"
      return 0
    fi
    sleep 1
  done

  echo "erro: timeout /ready em :9999" >&2
  return 1
}

collect_artifacts() {
  log "collect artifacts -> $RUN_DIR"
  docker compose -p "$COMPOSE_PROJECT_NAME" -f "$COMPOSE_FILE" ps --all >"$RUN_DIR/docker-compose.ps.txt" || true
  docker compose -p "$COMPOSE_PROJECT_NAME" -f "$COMPOSE_FILE" logs >"$RUN_DIR/docker-compose.logs.txt" || true
  docker stats --no-stream >"$RUN_DIR/docker-stats.txt" || true

  : >"$RUN_DIR/container-state.txt"
  echo "service|id|name|status|running|exit_code|oom_killed|restart_count|error|started_at|finished_at" >>"$RUN_DIR/container-state.txt"

  for service in lb api01 api02; do
    local id
    id="$(docker compose -p "$COMPOSE_PROJECT_NAME" -f "$COMPOSE_FILE" ps --all -q "$service" 2>/dev/null || true)"
    if [ -z "$id" ]; then
      continue
    fi

    docker inspect "$id" --format '{{json .}}' >"$RUN_DIR/${service}-inspect.json" || true
    docker inspect "$id" \
      --format "$service|{{.Id}}|{{.Name}}|{{.State.Status}}|{{.State.Running}}|{{.State.ExitCode}}|{{.State.OOMKilled}}|{{.RestartCount}}|{{.State.Error}}|{{.State.StartedAt}}|{{.State.FinishedAt}}" \
      >>"$RUN_DIR/container-state.txt" || true
  done
}

cleanup() {
  local exit_code=$?
  collect_artifacts

  if [ "$KEEP_UP" != "1" ]; then
    log "compose down"
    docker compose -p "$COMPOSE_PROJECT_NAME" -f "$COMPOSE_FILE" down --remove-orphans >/dev/null 2>&1 || true
  else
    log "KEEP_UP=1 -> containers mantidos"
  fi

  exit "$exit_code"
}
trap cleanup EXIT

require_cmd git
require_cmd docker
require_cmd curl
require_cmd jq
require_cmd rg
require_cmd k6

update_submission_repo
verify_submission_shape

log "compose down stale"
docker compose -p "$COMPOSE_PROJECT_NAME" -f "$COMPOSE_FILE" down --remove-orphans >/dev/null 2>&1 || true

if [ "$PULL_IMAGES" = "1" ]; then
  log "docker compose pull"
  docker compose -p "$COMPOSE_PROJECT_NAME" -f "$COMPOSE_FILE" pull
fi

log "compose up"
docker compose -p "$COMPOSE_PROJECT_NAME" -f "$COMPOSE_FILE" up -d
wait_ready

log "k6 run"
export K6_NO_USAGE_REPORT=true
k6 run --summary-mode "$K6_SUMMARY_MODE" --summary-export "$RUN_DIR/k6-summary.json" "$K6_SCRIPT" | tee "$RUN_DIR/k6-output.txt"
cp "$ROOT_DIR/test/results.json" "$RUN_DIR/results.json"

log "summary"
jq '{final_score: .scoring.final_score, p99: .p99, failure_rate: .scoring.failure_rate, breakdown: .scoring.breakdown}' "$RUN_DIR/results.json"

CURRENT_FINAL_SCORE="$(jq -r '.scoring.final_score' "$RUN_DIR/results.json")"
CURRENT_P99="$(jq -r '.p99' "$RUN_DIR/results.json")"
CURRENT_FAILURE_RATE="$(jq -r '.scoring.failure_rate' "$RUN_DIR/results.json")"

log "baseline compare"
printf 'baseline_final_score=%s\ncurrent_final_score=%s\nbaseline_p99=%s\ncurrent_p99=%s\nbaseline_failure_rate=%s\ncurrent_failure_rate=%s\n' \
  "$EXPECTED_FINAL_SCORE" "$CURRENT_FINAL_SCORE" \
  "$EXPECTED_P99" "$CURRENT_P99" \
  "$EXPECTED_FAILURE_RATE" "$CURRENT_FAILURE_RATE" | tee "$RUN_DIR/baseline-compare.txt"

log "done run_dir=$RUN_DIR"
