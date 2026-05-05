FROM elixir:1.19 AS build

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

COPY backend ./backend
COPY resources ./resources

WORKDIR /app/backend

ENV MIX_ENV=prod
RUN mix deps.get --only prod
RUN mix deps.compile
RUN mix compile
RUN mix rinha.build_index /app/resources /app/backend/priv/index
RUN mix release

FROM debian:trixie-slim AS runner

RUN apt-get update \
    && apt-get install -y --no-install-recommends libstdc++6 openssl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=build /app/backend/_build/prod/rel/backend ./backend
COPY --from=build /app/backend/priv/index ./index
COPY resources ./resources

ENV PORT=4000
ENV RINHA_RESOURCES_DIR=/app/resources
ENV INDEX_DIR=/app/index
ENV ERL_AFLAGS="+sbwt none +sbwtdcpu none +sbwtdio none"

EXPOSE 4000

CMD ["/app/backend/bin/backend", "start"]
