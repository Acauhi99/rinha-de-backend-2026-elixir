# Score Playbook (Source of Truth)

Status date: 2026-05-06

## Objective

Maximizar score da Rinha com iteracao rapida e rastreavel, sem perder reproducibilidade entre:

- ambiente local
- branch `main`
- branch `submission`
- preview oficial (`rinha/test`)

## Non-goals

- Nao otimizar por intuicao sem experimento controlado.
- Nao promover mudanca para `submission` sem passar gates.
- Nao usar `latest` para decidir submit.

## Branch strategy

- `main`: codigo-fonte e experimentos.
- `submission`: branch minima para execucao oficial (`docker-compose.yml`, `nginx.conf`, `info.json`).
- `submission-hyp-*`: branch temporaria para testes infra-only (ex: nginx), sem contaminar `submission`.

Regra: desenvolvimento acontece em `main`; `submission` so recebe variantes aprovadas.

## Image strategy

Para hipoteses com codigo Elixir:

1. Build/push com tag imutavel: `acauhi/rinha-2026-elixir:hyp-00X`
2. Resolver digest e travar compose com `@sha256:...`
3. Nunca usar `latest` para tomada de decisao

Para infra-only, manter mesma disciplina de rastreio (branch temporaria + artifacts), mesmo sem rebuild.

## Baseline canonica

Base oficial local para comparacao:

- comando: `make replay-8777799`
- referencia: commit `8777799` da branch `submission`
- ambiente: envelope da `submission` + imagem por digest

Baseline de decisao deve usar mediana de 3 runs completos.

## Experiment loop

1. Definir hipotese com 1 variavel (ou 1 bloco coeso) por vez.
2. Rodar triagem short.
3. Se promissora, rodar full.
4. Registrar resultado em artifacts + resumo.
5. Promover para `submission` apenas se passar gates.

## Standard run profiles

- Short (triagem): `K6_TARGET_RPS=450`, `K6_DURATION_SECONDS=45`
- Full (decisao): usar perfil completo do replay/baseline
- Condicoes: mesma maquina, sem outros containers, intervalo de 60s entre runs comparaveis

## Gates

### Gate global para promover variante para `submission`

Precisa cumprir todos:

1. `final_score` >= baseline local + 200
2. 2 runs full e ambos melhores que baseline comparavel
3. `failure_rate` nao piora mais que +0.3pp
4. `p99` nao piora mais que 10%

### Gate short atual para H1 (infra retry nginx)

1. `http_errors` cai em ambos os runs comparados
2. `p99` nao piora > 5% em nenhum
3. media de `final_score` da variante >= media control + 100

## Submission flow

1. Evoluir/validar em `main`.
2. Preparar artefatos (`make prepare-submission`) ou atualizar compose da branch minima.
3. Garantir imagem publica linux/amd64 e referenciada por digest no compose final de teste.
4. Atualizar branch `submission` (ou branch temporaria para pre-check).
5. Abrir issue no repo da Rinha com `rinha/test [id opcional]`.
6. Analisar comentario da engine e registrar no historico local.

## Artifact conventions

- Replay: `benchmarks/replay-8777799-<timestamp>/`
- Hipotese H1: `benchmarks/h1-<variant>-<run>-<timestamp>/`
- Suite H1: `benchmarks/h1-suite-<timestamp>/summary.md`

Campos minimos por run:

- `final_score`
- `p99`
- `failure_rate`
- `http_errors`

## Current state snapshot

- Baseline infra replay funcional (`make replay-8777799`).
- Runner H1 automatizado (`make hyp-h1`).
- Ultimo short H1 (2026-05-06) nao passou gate de promocao.

Resumo: [h1-suite-20260506-113933/summary.md](../benchmarks/h1-suite-20260506-113933/summary.md)

## Quick commands

```bash
# baseline replay
make replay-8777799

# short rapido de replay
K6_TARGET_RPS=450 K6_DURATION_SECONDS=45 make replay-8777799

# suite H1 (control x2 + h1 x2 + gate check)
make hyp-h1
```

