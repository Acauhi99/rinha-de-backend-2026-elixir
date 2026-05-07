# Backend (Elixir)

## Runtime

- API unica por instancia: expoe `GET /ready`, `GET /internal/metrics` e `POST /fraud-score`.
- Busca vetorial roda localmente em cada instancia (sem `engine` remoto).
- Listener pode ser TCP (`PORT`) ou Unix socket (`SOCKET_PATH`).

## Rodar local sem Docker

```bash
cd backend
mix deps.get
PORT=4000 RINHA_RESOURCES_DIR=../resources mix run --no-halt
```

## Build de indice

```bash
cd backend
mix rinha.build_index ../resources priv/index
```
