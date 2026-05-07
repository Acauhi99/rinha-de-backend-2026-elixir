#!/usr/bin/env bash
set -euo pipefail

COMPOSE_FILE=${COMPOSE_FILE:-docker-compose.local.yml}

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

docker compose -f "$COMPOSE_FILE" up -d --build
wait_ready

if command -v k6 >/dev/null 2>&1; then
  k6 run test/smoke.js
else
  echo "k6 nao encontrado. instale k6 para rodar smoke." >&2
fi
