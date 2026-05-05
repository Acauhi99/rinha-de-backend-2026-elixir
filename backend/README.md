# Backend (Elixir)

## Roles

- `APP_ROLE=api` -> expoe `GET /ready` e `POST /fraud-score`
- `APP_ROLE=engine` -> expoe `GET /ready` e `POST /internal/score`

## Rodar local sem Docker

```bash
cd backend
mix deps.get
APP_ROLE=api PORT=4000 RINHA_RESOURCES_DIR=../resources mix run --no-halt
```

## Build de indice

```bash
cd backend
mix rinha.build_index ../resources priv/index
```
