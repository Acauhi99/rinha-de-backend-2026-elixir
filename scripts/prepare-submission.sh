#!/usr/bin/env bash
set -euo pipefail

mkdir -p submission
cp docker-compose.yml submission/docker-compose.yml
cp nginx/nginx.conf submission/nginx.conf

echo "submission/docker-compose.yml atualizado"
echo "submission/nginx.conf atualizado"
echo "lembre de trocar ghcr.io/YOUR_GH_USER/rinha-2026-elixir:latest pela imagem publica real"
