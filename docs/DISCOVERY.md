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

