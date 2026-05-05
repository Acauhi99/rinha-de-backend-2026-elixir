# Discovery (estado atual)

Data da rodada: 2026-05-04

## Resultado observado (k6)

- `final_score`: `-2801.43`
- `p99`: `633.03ms`
- `failure_rate`: `62.39%`
- `false_positive_detections`: `1`
- `false_negative_detections`: `15909`
- `true_positive_detections`: `31`
- `true_negative_detections`: `19953`
- `http_errors`: `17245`

Sinal do runner:

- `Insufficient VUs`: limite de `250` VUs atingido
- `53139` iteracoes completas em `2m`

## Hipoteses mais fortes de gargalo

1. Saturacao do caminho API -> engine (latencia sobe, timeout em cascata).
2. Backpressure insuficiente no engine sob pico (queda de throughput efetivo).
3. Queda/instabilidade de containers ao final da rodada (conexao recusada em `4001/4002/4003` no teardown).
4. Recall ruim sob carga (muitos `false_negative_detections`) por degradacao de busca (timeout/corte agressivo de candidatos).

## O que NAO parece ser o gargalo primario

- Falso positivo quase inexistente (`1`), entao threshold/base de decisao nao eh o principal problema agora.

## Politica atual de experimento

Seguir `docs/EXPERIMENT_POLICY.md`:

- baseline fixo:
  - `hour_bins = 6`
  - `mcc_bins = 5`
  - `candidates_target = 6000`
  - `candidates_hard_cap = 10000`
  - `engine_timeout_ms = 10`
- alterar uma variavel por vez
- comparar mediana de 3 rodadas

## Proximos experimentos recomendados

1. Reduzir latencia de fila no engine (sem mudar regra de negocio): tuning de concorrencia e limites internos.
2. Ajustar `candidates_target` para baixo em passos pequenos (ex: `6000 -> 5000`) e medir impacto em `failure_rate` antes de mexer em threshold.
3. Ajustar timeout com cuidado (`10ms -> 12ms`) apenas se `http_errors` cair sem explodir `p99`.
4. Validar `container-state.txt` + `*-inspect.json` em toda rodada para detectar `oom_killed`/`exit_code` nao-zero.

## Regras da Rinha

As mudancas propostas ate aqui sao de implementacao/performance dentro do mesmo contrato HTTP e budget do compose local, sem quebra de regra estrutural conhecida da Rinha.
