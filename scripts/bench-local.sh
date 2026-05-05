#!/usr/bin/env bash
set -euo pipefail

COMPOSE_FILE=${COMPOSE_FILE:-docker-compose.local.yml}
OUT_DIR=${OUT_DIR:-benchmarks}
STAMP=$(date +"%Y%m%d-%H%M%S")
RUN_DIR="$OUT_DIR/$STAMP"
BUILD_TIMEOUT_SECONDS=${BUILD_TIMEOUT_SECONDS:-0}
BUILD_PROGRESS=${BUILD_PROGRESS:-plain}
KEEP_CONTAINERS_ON_FAIL=${KEEP_CONTAINERS_ON_FAIL:-0}
DOCKER_STATS_INTERVAL_SECONDS=${DOCKER_STATS_INTERVAL_SECONDS:-1}
K6_SUMMARY_MODE=${K6_SUMMARY_MODE:-full}
SKIP_BUILD=${SKIP_BUILD:-0}
K6_SCRIPT=${K6_SCRIPT:-test/test.js}

mkdir -p "$RUN_DIR"

EVENTS_FILE="$RUN_DIR/events.log"
DOCKER_STATS_STREAM_FILE="$RUN_DIR/docker-stats.stream.txt"
DOCKER_STATS_PID=""
RUN_START_EPOCH_MS=$(date +%s%3N)
DOCKER_CONFIG=${DOCKER_CONFIG:-$RUN_DIR/docker-config}
mkdir -p "$DOCKER_CONFIG"
export DOCKER_CONFIG

log_event() {
  local message="$1"
  local now_ms elapsed_ms
  now_ms=$(date +%s%3N)
  elapsed_ms=$((now_ms - RUN_START_EPOCH_MS))
  printf "%s\t+%06dms\t%s\n" "$(date -Iseconds)" "$elapsed_ms" "$message" >>"$EVENTS_FILE"
}

wait_ready() {
  log_event "wait_ready lb start"
  for _ in $(seq 1 120); do
    if curl -fsS http://localhost:9999/ready >/dev/null 2>&1; then
      log_event "wait_ready lb ok"
      return 0
    fi
    sleep 1
  done

  log_event "wait_ready lb timeout"
  echo "ready timeout" >&2
  return 1
}

wait_url_ready() {
  local url="$1"
  local name="$2"

  log_event "wait_ready $name start ($url)"
  for _ in $(seq 1 120); do
    if curl -fsS "$url" >/dev/null 2>&1; then
      log_event "wait_ready $name ok"
      return 0
    fi
    sleep 1
  done

  log_event "wait_ready $name timeout ($url)"
  echo "$name ready timeout ($url)" >&2
  return 1
}

collect_metrics() {
  if curl -fsS http://localhost:4001/internal/metrics >"$RUN_DIR/api01-metrics.json"; then
    :
  else
    printf '{"_error":"api01 metrics unavailable"}\n' >"$RUN_DIR/api01-metrics.json"
  fi

  if curl -fsS http://localhost:4002/internal/metrics >"$RUN_DIR/api02-metrics.json"; then
    :
  else
    printf '{"_error":"api02 metrics unavailable"}\n' >"$RUN_DIR/api02-metrics.json"
  fi

  printf '{}' >"$RUN_DIR/engine-metrics.json"
}

collect_container_state() {
  : >"$RUN_DIR/container-state.txt"
  echo "service|id|name|status|running|exit_code|oom_killed|restart_count|error|started_at|finished_at" >>"$RUN_DIR/container-state.txt"

  for service in api01 api02 lb; do
    local id
    id=$(docker compose -f "$COMPOSE_FILE" ps --all -q "$service" 2>/dev/null || true)

    if [ -z "$id" ]; then
      continue
    fi

    docker inspect "$id" \
      --format '{{json .}}' >"$RUN_DIR/${service}-inspect.json" || true

    docker inspect "$id" \
      --format "$service|{{.Id}}|{{.Name}}|{{.State.Status}}|{{.State.Running}}|{{.State.ExitCode}}|{{.State.OOMKilled}}|{{.RestartCount}}|{{.State.Error}}|{{.State.StartedAt}}|{{.State.FinishedAt}}" \
      >>"$RUN_DIR/container-state.txt" || true
  done
}

start_docker_stats_stream() {
  : >"$DOCKER_STATS_STREAM_FILE"
  (
    while true; do
      printf "# %s\n" "$(date -Iseconds)"
      docker stats --no-stream >>"$DOCKER_STATS_STREAM_FILE" 2>/dev/null || true
      sleep "$DOCKER_STATS_INTERVAL_SECONDS"
    done
  ) &
  DOCKER_STATS_PID=$!
  log_event "docker stats stream started pid=$DOCKER_STATS_PID interval=${DOCKER_STATS_INTERVAL_SECONDS}s"
}

stop_docker_stats_stream() {
  if [ -n "${DOCKER_STATS_PID:-}" ] && kill -0 "$DOCKER_STATS_PID" 2>/dev/null; then
    kill "$DOCKER_STATS_PID" 2>/dev/null || true
    wait "$DOCKER_STATS_PID" 2>/dev/null || true
    log_event "docker stats stream stopped pid=$DOCKER_STATS_PID"
  fi
}

cleanup() {
  local exit_code=$?

  stop_docker_stats_stream
  collect_metrics
  collect_container_state
  docker compose -f "$COMPOSE_FILE" logs >"$RUN_DIR/docker-compose.logs.txt" || true
  docker stats --no-stream >"$RUN_DIR/docker-stats.txt" || true
  docker compose -f "$COMPOSE_FILE" ps --all >"$RUN_DIR/docker-compose.ps.txt" || true

  if [ "$exit_code" -ne 0 ]; then
    echo "bench falhou (exit=$exit_code). status containers:" >&2
    docker compose -f "$COMPOSE_FILE" ps >&2 || true
    echo "ultimas linhas logs api01/api02/lb:" >&2
    docker compose -f "$COMPOSE_FILE" logs --tail 120 api01 api02 lb >&2 || true
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

  log_event "compose build start"
  "${cmd[@]}"
  log_event "compose build done"
}

if [ "$SKIP_BUILD" = "1" ]; then
  log_event "compose build skipped"
else
  run_compose_build
fi
# Avoid nginx DNS race: bring backend services up first, then lb.
log_event "compose up api01 api02"
docker compose -f "$COMPOSE_FILE" up -d api01 api02
wait_url_ready "http://localhost:4001/ready" "api01"
wait_url_ready "http://localhost:4002/ready" "api02"
log_event "compose up lb"
docker compose -f "$COMPOSE_FILE" up -d lb
wait_ready
start_docker_stats_stream

if ! command -v k6 >/dev/null 2>&1; then
  echo "k6 nao encontrado. instale k6 para benchmark." >&2
  exit 1
fi

log_event "k6 start"
k6 run --summary-mode "$K6_SUMMARY_MODE" --summary-export "$RUN_DIR/k6-summary.json" "$K6_SCRIPT" | tee "$RUN_DIR/k6-output.txt"
log_event "k6 done"
cp test/results.json "$RUN_DIR/results.json"

jq '{final_score: .scoring.final_score, p99: .p99, failure_rate: .scoring.failure_rate, breakdown: .scoring.breakdown}' "$RUN_DIR/results.json"
