#!/usr/bin/env bash
set -euo pipefail

mkdir -p submission
cp docker-compose.yml submission/docker-compose.yml
cp nginx/nginx.conf submission/nginx.conf
cp info.json submission/info.json

# Na branch `submission` o arquivo fica na raiz, sem pasta `nginx/`.
sed -i 's#\./nginx/nginx\.conf#./nginx.conf#g' submission/docker-compose.yml

echo "submission/docker-compose.yml atualizado"
echo "submission/nginx.conf atualizado"
echo "submission/info.json atualizado"
echo "lembre de validar se a imagem publicada em docker-compose.yml esta correta"
