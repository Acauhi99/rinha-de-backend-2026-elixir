#!/usr/bin/env bash
set -euo pipefail

mkdir -p submission
cp docker-compose.yml submission/docker-compose.yml
cp nginx/nginx.conf submission/nginx.conf

# Na branch `submission` o arquivo fica na raiz, sem pasta `nginx/`.
sed -i 's#\./nginx/nginx\.conf#./nginx.conf#g' submission/docker-compose.yml

echo "submission/docker-compose.yml atualizado"
echo "submission/nginx.conf atualizado"
echo "lembre de trocar acauhi/rinha-2026-elixir:latest pela imagem publica real"
