# Setup local (Elixir)

## Topologia

- `lb` (porta `9999`)
- `api01`
- `api02`
- `engine` compartilhado

## Budget oficial aplicado

- CPU total: `1.0`
- Mem total: `350MB`

Distribuicao atual:

- `lb`: `0.10 CPU`, `10MB`
- `api01`: `0.125 CPU`, `70MB`
- `api02`: `0.125 CPU`, `70MB`
- `engine`: `0.65 CPU`, `200MB`

## Pipeline

- Build gera indice vetorial (`priv/index`) a partir de `resources/references.json.gz`.
- API vetoriza payload (14 dimensoes) e chama engine interno.
- Engine aplica busca em 2 estagios:
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

`make bench` salva artefatos em `benchmarks/<timestamp>/`:

- `results.json`
- `api01-metrics.json`
- `api02-metrics.json`
- `engine-metrics.json`
- `container-state.txt`
- `api01-inspect.json`
- `api02-inspect.json`
- `engine-inspect.json`
- `lb-inspect.json`
- `docker-compose.logs.txt`
- `docker-stats.txt`
- `docker-compose.ps.txt`

## Metricas para decidir

- `final_score`, `p99`, `failure_rate` (k6)
- `engine_latency_us` p50/p95/p99 (api metrics)
- `candidate_count` p50/p95/p99 (api/engine metrics)
- `fallback_count` (api metrics)
- CPU/MEM por container (docker stats)

Discovery atual e gargalos observados: `docs/DISCOVERY.md`.
