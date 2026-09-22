#!/usr/bin/env bash
# Sobe o front-end MyWatchList localmente sem Docker.
# Sem dependências para instalar: é HTML/CSS/JS puro, Bootstrap vem via CDN no navegador.
# Só serve os arquivos estáticos. Requer a API rodando em http://localhost:8000 (ver mywatchlist-api/run.sh).
set -euo pipefail
cd "$(dirname "$0")"

PORT="${1:-3001}"

echo "Front-end em http://localhost:${PORT} — Ctrl+C para parar."
exec python3 -m http.server "$PORT"
