# Experiment Policy

Objetivo: melhorar score com mudanca controlada por dados.

## Regra dura

- Um experimento altera **1 variavel por vez**.
- Antes de alterar variavel, rodar baseline **3 vezes** no mesmo commit.
- Comparacao usa mediana das 3 rodadas.

## Baseline atual (fixo)

- `hour_bins = 6`
- `mcc_bins = 5`
- `candidates_target = 6000`
- `candidates_hard_cap = 10000`
- `engine_timeout_ms = 10`

## Metricas obrigatorias por rodada

- `final_score`
- `p99`
- `failure_rate`
- `engine_latency_us` (`p50`, `p95`, `p99`)
- `candidate_count` (`p50`, `p95`, `p99`)
- `fallback_count`
- CPU/MEM snapshot por container
- `exit_code` + `oom_killed` por container (`container-state.txt`)

## Critério de aceite de mudança

Mudanca entra somente se:

1. `failure_rate` nao piora, e
2. `final_score` mediano sobe de forma consistente (>= 2 de 3 rodadas com ganho).

## Registro

Salvar cada rodada em `benchmarks/<timestamp>/` (ja automatizado no script).

Criar resumo manual em `benchmarks/summary.md` com:

- commit
- variavel alterada
- baseline mediano
- variante mediano
- decisao (keep/revert)
