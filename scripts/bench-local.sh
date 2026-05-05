#!/usr/bin/env bash
set -euo pipefail

COMPOSE_FILE=${COMPOSE_FILE:-docker-compose.local.yml}
OUT_DIR=${OUT_DIR:-benchmarks}
STAMP=$(date +"%Y%m%d-%H%M%S")
RUN_DIR="$OUT_DIR/$STAMP"
BUILD_TIMEOUT_SECONDS=${BUILD_TIMEOUT_SECONDS:-0}
BUILD_PROGRESS=${BUILD_PROGRESS:-plain}
KEEP_CONTAINERS_ON_FAIL=${KEEP_CONTAINERS_ON_FAIL:-0}

mkdir -p "$RUN_DIR"

wait_ready() {
  for _ in $(seq 1 120); do
    if curl -fsS http://localhost:9999/ready >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  echo "ready timeout" >&2
  return 1
}

wait_url_ready() {
  local url="$1"
  local name="$2"

  for _ in $(seq 1 120); do
    if curl -fsS "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  echo "$name ready timeout ($url)" >&2
  return 1
}

collect_metrics() {
  curl -fsS http://localhost:4001/internal/metrics >"$RUN_DIR/api01-metrics.json" || true
  curl -fsS http://localhost:4002/internal/metrics >"$RUN_DIR/api02-metrics.json" || true
  curl -fsS http://localhost:4003/internal/metrics >"$RUN_DIR/engine-metrics.json" || true
}

collect_container_state() {
  : >"$RUN_DIR/container-state.txt"
  echo "service|id|name|status|running|exit_code|oom_killed|error|started_at|finished_at" >>"$RUN_DIR/container-state.txt"

  for service in api01 api02 engine lb; do
    local id
    id=$(docker compose -f "$COMPOSE_FILE" ps --all -q "$service" 2>/dev/null || true)

    if [ -z "$id" ]; then
      continue
    fi

    docker inspect "$id" \
      --format '{{json .}}' >"$RUN_DIR/${service}-inspect.json" || true

    docker inspect "$id" \
      --format "$service|{{.Id}}|{{.Name}}|{{.State.Status}}|{{.State.Running}}|{{.State.ExitCode}}|{{.State.OOMKilled}}|{{.State.Error}}|{{.State.StartedAt}}|{{.State.FinishedAt}}" \
      >>"$RUN_DIR/container-state.txt" || true
  done
}

cleanup() {
  local exit_code=$?

  collect_metrics
  collect_container_state
  docker compose -f "$COMPOSE_FILE" logs >"$RUN_DIR/docker-compose.logs.txt" || true
  docker stats --no-stream >"$RUN_DIR/docker-stats.txt" || true
  docker compose -f "$COMPOSE_FILE" ps --all >"$RUN_DIR/docker-compose.ps.txt" || true

  if [ "$exit_code" -ne 0 ]; then
    echo "bench falhou (exit=$exit_code). status containers:" >&2
    docker compose -f "$COMPOSE_FILE" ps >&2 || true
    echo "ultimas linhas logs api01/api02/engine/lb:" >&2
    docker compose -f "$COMPOSE_FILE" logs --tail 120 api01 api02 engine lb >&2 || true
  fi

  if [ "$exit_code" -ne 0 ] && [ "$KEEP_CONTAINERS_ON_FAIL" = "1" ]; then
    echo "KEEP_CONTAINERS_ON_FAIL=1 -> mantendo containers no ar para debug" >&2
    return 0
  fi

  docker compose -f "$COMPOSE_FILE" down --remove-orphans || true
}
trap cleanup EXIT

run_compose_build() {
  local cmd=(docker compose --progress "$BUILD_PROGRESS" -f "$COMPOSE_FILE" build)

  if [ "$BUILD_TIMEOUT_SECONDS" -gt 0 ]; then
    local timeout_cmd=""

    if command -v timeout >/dev/null 2>&1; then
      timeout_cmd="timeout"
    elif command -v gtimeout >/dev/null 2>&1; then
      timeout_cmd="gtimeout"
    fi

    if [ -n "$timeout_cmd" ]; then
      "$timeout_cmd" --foreground "$BUILD_TIMEOUT_SECONDS" "${cmd[@]}"
      return $?
    fi

    echo "timeout/gtimeout nao encontrado; rodando build sem timeout" >&2
  fi

  "${cmd[@]}"
}

run_compose_build
# Avoid nginx DNS race: bring backend services up first, then lb.
docker compose -f "$COMPOSE_FILE" up -d engine api01 api02
wait_url_ready "http://localhost:4001/ready" "api01"
wait_url_ready "http://localhost:4002/ready" "api02"
wait_url_ready "http://localhost:4003/ready" "engine"
docker compose -f "$COMPOSE_FILE" up -d lb
wait_ready

if ! command -v k6 >/dev/null 2>&1; then
  echo "k6 nao encontrado. instale k6 para benchmark." >&2
  exit 1
fi

k6 run test/test.js
cp test/results.json "$RUN_DIR/results.json"

jq '{final_score: .scoring.final_score, p99: .p99, failure_rate: .scoring.failure_rate, breakdown: .scoring.breakdown}' "$RUN_DIR/results.json"
