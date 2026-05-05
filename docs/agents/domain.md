# Domain Docs

Como skills de engenharia devem consumir docs de domínio ao explorar código.

## Ler antes de explorar

- `CONTEXT.md` na raiz.
- `docs/adr/` para decisões arquiteturais passadas.

Se arquivo não existir, seguir fluxo sem bloquear.

## Layout deste repo

`single-context`.

Estrutura esperada:

```
/
├── CONTEXT.md
├── docs/adr/
└── src/
```

## Vocabulário

Quando nomear conceito de domínio (issue, proposta, teste), preferir termos definidos em `CONTEXT.md`.

## Conflitos com ADR

Se proposta contradizer ADR existente, explicitar conflito e motivo de reabertura.
