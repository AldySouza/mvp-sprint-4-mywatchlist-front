#!/usr/bin/env bash
# Sobe mywatchlist-front + mywatchlist-api via Docker Compose.
# Requer que o repositório mywatchlist-api esteja clonado ao lado deste
# (mesmo diretório pai) — é o que o docker-compose.yml espera em `context`.
set -euo pipefail

cd "$(dirname "$0")"

wait_for_docker() {
  local tries=0
  until docker info >/dev/null 2>&1; do
    tries=$((tries + 1))
    if [ "$tries" -gt 30 ]; then
      echo "Docker não respondeu a tempo. Abra o Docker Desktop manualmente e rode este script de novo." >&2
      exit 1
    fi
    sleep 2
  done
}

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker não encontrado. Instale em https://docs.docker.com/get-docker/ e rode este script de novo." >&2
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "Docker não está rodando. Tentando iniciar..."
  if [ "$(uname -s)" = "Darwin" ] && [ -d "/Applications/Docker.app" ]; then
    open -a Docker
  elif command -v systemctl >/dev/null 2>&1; then
    systemctl start docker 2>/dev/null || sudo systemctl start docker 2>/dev/null || true
  fi
  echo "Aguardando o Docker iniciar (pode levar até 1 minuto na primeira vez)..."
  wait_for_docker
fi

if [ ! -d "../mywatchlist-api" ]; then
  echo "Aviso: não encontrei ../mywatchlist-api. Clone os dois repositórios no mesmo diretório pai." >&2
fi

echo "Docker pronto. Subindo mywatchlist-front + mywatchlist-api via docker compose..."
echo "Front-end: http://localhost:3001"
echo "API (Swagger UI): http://localhost:8000/docs"
exec docker compose up --build
