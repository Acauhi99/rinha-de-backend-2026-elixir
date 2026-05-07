# Discovery Log

Fonte de verdade de estrategia: [SCORE_PLAYBOOK.md](./SCORE_PLAYBOOK.md)

Este arquivo fica como log curto de descobertas e decisoes.

## 2026-05-06 - Baseline e H1

- Baseline de replay local consolidada via `make replay-8777799`.
- Runner de hipotese H1 criado: `make hyp-h1`.
- Hipotese H1 testada (`proxy_next_upstream_tries 2 -> 1` em `/fraud-score`).
- Resultado H1 short: nao promovido (falhou gates definidos).
- Evidencia: `benchmarks/h1-suite-20260506-113933/summary.md`.

## Proxima frente

- H2 focado em HTTP/p99 no nginx, mantendo regra de 1 variavel por vez.

## 2026-05-06 - H2/H3 (detecção)

- H2 (`CANDIDATES_TARGET`): melhor short foi `1400`, com FN menor e `score_det` maior, mas sem passar criterio rigido definido.
- Full estável de `t1400` (4 runs): `final_score` medio `3314.05`, `p99` medio `1.46ms`.
- Baseline full comparavel (`control=1000`, 2 runs): `final_score` medio `3329.87`, `p99` medio `1.26ms`.
- H3 (ordem de rings priorizando `unknown_merchant`) no full ficou instavel e pior no A/B/A/B:
  - `A=H3 target=1400`: `final_score` `1180.82` e `888.16`, `p99` `199.35ms` e `390.65ms`, `dropped_iterations` `97` e `158`.
  - `B=control target=1000`: `final_score` `3250.91` e `3257.87`, `p99` `1.50ms` e `1.48ms`, `dropped_iterations` `0`.
- Decisao: nao promover H3; revertido.
