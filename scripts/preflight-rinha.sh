#!/usr/bin/env bash
set -euo pipefail

COMPOSE_FILE=${COMPOSE_FILE:-docker-compose.yml}
RUN_RUNTIME_CHECKS=${RUN_RUNTIME_CHECKS:-1}

fail_count=0

pass() {
  echo "PASS: $1"
}

fail() {
  echo "FAIL: $1"
  fail_count=$((fail_count + 1))
}

require_file() {
  local file="$1"
  if [ -f "$file" ]; then
    pass "arquivo presente: $file"
  else
    fail "arquivo ausente: $file"
  fi
}

check_required_services() {
  local services
  services=$(awk '
    $1 == "services:" { in_services = 1; next }
    in_services && /^[^[:space:]]/ { in_services = 0 }
    in_services && /^[[:space:]]{2}[a-zA-Z0-9_-]+:/ {
      name = $1
      sub(":", "", name)
      print name
    }
  ' "$COMPOSE_FILE")

  for svc in lb api01 api02; do
    if echo "$services" | rg -x "$svc" >/dev/null; then
      pass "servico obrigatorio presente: $svc"
    else
      fail "servico obrigatorio ausente: $svc"
    fi
  done
}

check_resource_limits() {
  local cpu_sum mem_sum

  cpu_sum=$(awk '
    /cpus:[[:space:]]*/ {
      v = $2
      gsub(/"/, "", v)
      sum += v + 0
    }
    END { printf "%.3f", sum + 0 }
  ' "$COMPOSE_FILE")

  mem_sum=$(awk '
    /memory:[[:space:]]*/ {
      raw = $2
      gsub(/"/, "", raw)
      n = raw
      u = raw
      sub(/[A-Za-z]+$/, "", n)
      sub(/^[0-9.]+/, "", u)
      u = tolower(u)

      if (u == "mb" || u == "m") sum += n
      else if (u == "gb" || u == "g") sum += n * 1024
      else if (u == "kb" || u == "k") sum += n / 1024
      else if (u == "b") sum += n / (1024 * 1024)
      else bad = 1
    }
    END {
      if (bad) print "BAD_UNIT"
      else printf "%.2f", sum + 0
    }
  ' "$COMPOSE_FILE")

  if [ "$mem_sum" = "BAD_UNIT" ]; then
    fail "unidade de memoria nao suportada no compose"
  else
    echo "INFO: soma CPU=$cpu_sum soma MEM=${mem_sum}MB"
    awk -v c="$cpu_sum" 'BEGIN { exit (c <= 1.000 ? 0 : 1) }' && pass "CPU total <= 1.0" || fail "CPU total > 1.0"
    awk -v m="$mem_sum" 'BEGIN { exit (m <= 350.0 ? 0 : 1) }' && pass "memoria total <= 350MB" || fail "memoria total > 350MB"
  fi
}

check_forbidden_compose_flags() {
  if rg -n 'network_mode:[[:space:]]*"?host"?' "$COMPOSE_FILE" >/dev/null; then
    fail "network_mode: host encontrado"
  else
    pass "network_mode host nao encontrado"
  fi

  if rg -n 'privileged:[[:space:]]*true' "$COMPOSE_FILE" >/dev/null; then
    fail "privileged: true encontrado"
  else
    pass "privileged true nao encontrado"
  fi
}

collect_service_images() {
  awk '
    $1 == "services:" { in_services = 1; next }
    in_services && /^[^[:space:]]/ { in_services = 0 }
    in_services && /^[[:space:]]{2}[a-zA-Z0-9_-]+:/ {
      svc = $1
      sub(":", "", svc)
    }
    in_services && /^[[:space:]]{4}image:[[:space:]]*/ {
      img = $2
      gsub(/"/, "", img)
      print svc "\t" img
    }
  ' "$COMPOSE_FILE"
}

check_images_public_amd64() {
  local pairs pair svc img
  pairs=$(collect_service_images)

  if [ -z "$pairs" ]; then
    fail "nenhuma imagem encontrada em $COMPOSE_FILE"
    return
  fi

  while IFS=$'\t' read -r svc img; do
    if [ -z "$svc" ] || [ -z "$img" ]; then
      continue
    fi

    if docker manifest inspect "$img" >/tmp/preflight-manifest.json 2>/dev/null; then
      pass "imagem acessivel publicamente: $svc -> $img"
      if jq -e 'any(.manifests[]?; .platform.os == "linux" and .platform.architecture == "amd64")' /tmp/preflight-manifest.json >/dev/null; then
        pass "imagem com linux/amd64: $svc -> $img"
      else
        fail "imagem sem linux/amd64: $svc -> $img"
      fi
    else
      fail "imagem nao acessivel via docker manifest: $svc -> $img"
    fi
  done <<<"$pairs"
}

runtime_cleanup() {
  docker compose -f "$COMPOSE_FILE" down --remove-orphans >/dev/null 2>&1 || true
}

wait_ready() {
  for _ in $(seq 1 120); do
    code=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:9999/ready || true)
    if [ "$code" = "200" ]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

check_runtime_endpoints() {
  trap runtime_cleanup RETURN

  if ! docker compose -f "$COMPOSE_FILE" up -d --build >/tmp/preflight-up.log 2>&1; then
    fail "docker compose up --build falhou"
    return
  fi

  if wait_ready; then
    pass "GET /ready respondeu 200 em :9999"
  else
    fail "GET /ready nao respondeu 200 em :9999"
    return
  fi

  local fraud_code metrics_code
  fraud_code=$(curl -s -o /dev/null -w '%{http_code}' -X POST http://localhost:9999/fraud-score \
    -H 'content-type: application/json' \
    --data '{"id":"tx-preflight","transaction":{"amount":10.0,"installments":1,"requested_at":"2026-03-11T20:23:35Z"},"customer":{"avg_amount":10.0,"tx_count_24h":1,"known_merchants":["MERC-001"]},"merchant":{"id":"MERC-001","mcc":"5912","avg_amount":10.0},"terminal":{"is_online":false,"card_present":true,"km_from_home":1.0},"last_transaction":null}' || true)

  metrics_code=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:9999/internal/metrics || true)

  if [ "$fraud_code" = "200" ]; then
    pass "POST /fraud-score respondeu 200 em :9999"
  else
    fail "POST /fraud-score nao respondeu 200 (codigo=$fraud_code)"
  fi

  if [ "$metrics_code" = "404" ] || [ "$metrics_code" = "405" ]; then
    pass "endpoint interno nao exposto publicamente em :9999 (/internal/metrics -> $metrics_code)"
  else
    fail "endpoint interno aparenta exposto em :9999 (/internal/metrics -> $metrics_code)"
  fi
}

echo "== preflight rinha =="
echo "compose: $COMPOSE_FILE"

require_file "$COMPOSE_FILE"
require_file "info.json"

check_required_services
check_resource_limits
check_forbidden_compose_flags
check_images_public_amd64

if [ "$RUN_RUNTIME_CHECKS" = "1" ]; then
  check_runtime_endpoints
else
  echo "INFO: runtime checks desativados (RUN_RUNTIME_CHECKS=$RUN_RUNTIME_CHECKS)"
fi

echo
if [ "$fail_count" -eq 0 ]; then
  echo "PRECHECK: OK"
  exit 0
fi

echo "PRECHECK: FALHOU ($fail_count problema(s))"
exit 1
