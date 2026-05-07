# Setup local (Elixir)

Estrategia, objetivos e gates de score:

- [SCORE_PLAYBOOK.md](./SCORE_PLAYBOOK.md)

## Topologia

- `lb` (porta `9999`)
- `api01`
- `api02`

## Budget oficial aplicado

- CPU total: `1.0`
- Mem total: `350MB`

Distribuicao atual:

- `lb`: `0.10 CPU`, `20MB`
- `api01`: `0.45 CPU`, `165MB`
- `api02`: `0.45 CPU`, `165MB`

## Pipeline

- Build gera indice vetorial (`priv/index`) a partir de `resources/references.json.gz`.
- API vetoriza payload (14 dimensoes) e aplica busca local.
- Busca local em 2 estagios:
  1. Buckets aproximados
  2. KNN exato (L2 quadratica, sem `sqrt`) nos candidatos

## Comandos

```bash
make up
make smoke
make bench
make down
```

## Replay exato da preview (commit 8777799)

Para reproduzir localmente a mesma submissao que gerou score `-3606.02`:

```bash
make replay-8777799
```

Modo agil para testar hipoteses rapidas (menos carga/duracao):

```bash
K6_TARGET_RPS=450 K6_DURATION_SECONDS=45 make replay-8777799
```

O script faz checkout do commit da branch `submission`, valida digest da imagem e limites (LB `0.10/10MB`, APIs `0.45/170MB`), roda k6 e salva artefatos em `benchmarks/replay-8777799-<timestamp>/`.

## Runner de hipotese H1 (infra-only)

Executa `control x2` e `h1 x2` no envelope da `submission`, gera artefatos e `summary.md` com gates:

```bash
make hyp-h1
```

Padrao atual:

- `K6_TARGET_RPS=450`
- `K6_DURATION_SECONDS=45`
- intervalo entre runs: `60s`

`make bench` salva artefatos em `benchmarks/<timestamp>/`:

- `results.json`
- `api01-metrics.json`
- `api02-metrics.json`
- `container-state.txt`
- `api01-inspect.json`
- `api02-inspect.json`
- `lb-inspect.json`
- `docker-compose.logs.txt`
- `docker-stats.txt`
- `docker-compose.ps.txt`

## Metricas para decidir

- `final_score`, `p99`, `failure_rate` (k6)
- `engine_latency_us` p50/p95/p99 (api metrics)
- `candidate_count` p50/p95/p99 (api metrics)
- `fallback_count` (api metrics)
- CPU/MEM por container (docker stats)

Log de descobertas: [DISCOVERY.md](./DISCOVERY.md)
