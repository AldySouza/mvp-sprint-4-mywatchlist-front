#!/usr/bin/env bash
# Sobe a aplicação MyWatchList completa (front + API) num computador sem nada
# pré-instalado.
#
# Verifica (e instala, se faltar) o Python na versão certa e o Docker, e baixa
# o repositório da API se ele não estiver ao lado deste (../mvp-sprint-4-mywatchlist-api).
# Com o Docker rodando, sobe tudo via docker compose; se o Docker não ficar
# pronto (ex.: recém-instalado e pedindo logout/login), sobe com Python local.
#
#   ./start.sh           Docker, ou Python local como alternativa
#   ./start.sh --local   direto com Python local, sem Docker
set -euo pipefail

cd "$(dirname "$0")"

FRONT_PORT=3001
API_PORT=8000  # fixo em app.js (API_BASE_URL)
API_URL="http://localhost:${API_PORT}"
API_DIR="../mvp-sprint-4-mywatchlist-api"
API_REPO="https://github.com/AldySouza/mvp-sprint-4-mywatchlist-api"
# pydantic 2.9 / fastapi 0.115 (API) têm wheels prontos do Python 3.10 ao 3.13.
PY_VERSION_CHECK='import sys; sys.exit(0 if (3, 10) <= sys.version_info[:2] <= (3, 13) else 1)'
PY_MAC_PKG="https://www.python.org/ftp/python/3.12.10/python-3.12.10-macos11.pkg"
DOCKER_APP_BIN="/Applications/Docker.app/Contents/Resources/bin"

fail() {
  echo "Erro: $*" >&2
  exit 1
}

sudo_cmd() {
  if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi
}

# ---------------------------------------------------------------- Python

python_ok() {
  "$1" -c "$PY_VERSION_CHECK; import venv, ensurepip" >/dev/null 2>&1
}

find_python() {
  local c p
  for c in python3.12 python3.13 python3.11 python3.10 python3 python \
    /opt/homebrew/bin/python3.12 /usr/local/bin/python3.12 \
    /Library/Frameworks/Python.framework/Versions/3.12/bin/python3; do
    p="$(command -v "$c" 2>/dev/null)" || continue
    # No macOS sem Xcode CLT, /usr/bin/python3 é só um atalho que abre um instalador.
    if [ "$p" = "/usr/bin/python3" ] && [ "$(uname -s)" = "Darwin" ] && ! xcode-select -p >/dev/null 2>&1; then
      continue
    fi
    if python_ok "$p"; then
      PYTHON="$p"
      return 0
    fi
  done
  return 1
}

install_python() {
  echo "    Python 3.10–3.13 não encontrado. Instalando Python 3.12 (só na primeira vez)..."
  case "$(uname -s)" in
    Darwin)
      if command -v brew >/dev/null 2>&1; then
        brew install python@3.12
      else
        local pkg
        pkg="$(mktemp -d)/python.pkg"
        curl -fL --progress-bar -o "$pkg" "$PY_MAC_PKG"
        echo "    O instalador do Python precisa da sua senha de administrador."
        sudo installer -pkg "$pkg" -target /
      fi
      ;;
    Linux)
      if command -v apt-get >/dev/null 2>&1; then
        sudo_cmd apt-get update
        sudo_cmd apt-get install -y python3.12 python3.12-venv \
          || sudo_cmd apt-get install -y python3 python3-venv
      elif command -v dnf >/dev/null 2>&1; then
        sudo_cmd dnf install -y python3.12 || sudo_cmd dnf install -y python3
      elif command -v yum >/dev/null 2>&1; then
        sudo_cmd yum install -y python3
      elif command -v pacman >/dev/null 2>&1; then
        sudo_cmd pacman -Sy --noconfirm python
      elif command -v zypper >/dev/null 2>&1; then
        sudo_cmd zypper install -y python312 || sudo_cmd zypper install -y python3
      elif command -v apk >/dev/null 2>&1; then
        sudo_cmd apk add python3
      else
        fail "não sei instalar Python nesta distribuição. Instale o Python 3.12 (https://www.python.org/downloads/) e rode este script de novo."
      fi
      ;;
    *)
      fail "sistema não suportado por este script. No Windows, use start.bat ou start.ps1."
      ;;
  esac
  hash -r
  find_python || fail "o Python instalado não é compatível (precisa ser 3.10 a 3.13). Instale o Python 3.12 em https://www.python.org/downloads/ e rode este script de novo."
}

url_up() {
  "$PYTHON" -c 'import sys, urllib.request; urllib.request.urlopen(sys.argv[1], timeout=2)' "$1" >/dev/null 2>&1
}

port_free() {
  # Livre = ninguém escutando nela (bind falharia com conexões antigas em TIME_WAIT).
  ! "$PYTHON" -c 'import socket, sys; socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=1)' "$1" >/dev/null 2>&1
}

# ---------------------------------------------------------------- Docker

add_docker_app_to_path() {
  # O Docker Desktop só cria o atalho em /usr/local/bin na primeira abertura.
  if [ -d "$DOCKER_APP_BIN" ]; then PATH="$PATH:$DOCKER_APP_BIN"; fi
}

docker_running() {
  docker info >/dev/null 2>&1
}

wait_for_docker() {
  local waited=0
  until docker_running; do
    [ "$waited" -ge "$1" ] && return 1
    sleep 2
    waited=$((waited + 2))
  done
}

install_docker() {
  echo "    Docker não encontrado. Instalando (só na primeira vez)..."
  case "$(uname -s)" in
    Darwin)
      if command -v brew >/dev/null 2>&1; then
        brew install --cask docker || return 1
      else
        local arch dmg mnt rc=0
        arch="$([ "$(uname -m)" = "arm64" ] && echo arm64 || echo amd64)"
        dmg="$(mktemp -d)/Docker.dmg"
        curl -fL --progress-bar -o "$dmg" "https://desktop.docker.com/mac/main/$arch/Docker.dmg" || return 1
        mnt="$(mktemp -d)"
        hdiutil attach -nobrowse -quiet -mountpoint "$mnt" "$dmg" || return 1
        echo "    Copiar o Docker para /Applications precisa da sua senha de administrador."
        sudo cp -R "$mnt/Docker.app" /Applications/ || rc=1
        hdiutil detach -quiet "$mnt" || true
        return "$rc"
      fi
      ;;
    Linux)
      # Script oficial de instalação do Docker Engine + Compose.
      curl -fsSL https://get.docker.com | sudo_cmd sh || return 1
      sudo_cmd systemctl enable --now docker 2>/dev/null || true
      if [ "$(id -u)" -ne 0 ]; then
        sudo usermod -aG docker "$USER" || true
        echo "    Docker instalado. Para usá-lo sem sudo, faça logout/login (ou reinicie) e rode este script de novo."
      fi
      ;;
    *)
      return 1
      ;;
  esac
}

# Retorna 0 se, no fim, o Docker estiver instalado e rodando.
ensure_docker() {
  add_docker_app_to_path
  if ! command -v docker >/dev/null 2>&1; then
    install_docker || { echo "    Não consegui instalar o Docker."; return 1; }
    add_docker_app_to_path
    hash -r
  fi
  docker_running && return 0

  echo "    Docker não está rodando. Tentando iniciar..."
  local timeout=30
  if [ "$(uname -s)" = "Darwin" ] && [ -d "/Applications/Docker.app" ]; then
    open -a Docker
    timeout=120
    echo "    Aguardando o Docker iniciar (até 2 min; na primeira vez, aceite os termos na janela do Docker Desktop)..."
  elif command -v systemctl >/dev/null 2>&1; then
    sudo_cmd systemctl start docker 2>/dev/null || true
  fi
  wait_for_docker "$timeout"
}

# ---------------------------------------------------------------- API

ensure_api_repo() {
  [ -d "$API_DIR" ] && return 0
  echo "    Não encontrei $API_DIR. Baixando o repositório da API..."
  if command -v git >/dev/null 2>&1 && { [ "$(uname -s)" != "Darwin" ] || xcode-select -p >/dev/null 2>&1; }; then
    git clone "$API_REPO.git" "$API_DIR"
  else
    mkdir -p "$API_DIR"
    curl -fL "$API_REPO/archive/refs/heads/main.tar.gz" | tar -xz --strip-components=1 -C "$API_DIR"
  fi
}

open_browser() {
  if [ "$(uname -s)" = "Darwin" ]; then
    open "$1"
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$1"
  fi
}

# Abre o navegador assim que o front responder.
open_browser_when_ready() {
  (
    for _ in $(seq 1 300); do
      if url_up "http://localhost:${FRONT_PORT}"; then
        open_browser "http://localhost:${FRONT_PORT}"
        exit 0
      fi
      sleep 1
    done
  ) >/dev/null 2>&1 &
}

print_urls() {
  echo
  echo "  Aplicação:        http://localhost:${FRONT_PORT}"
  echo "  API (Swagger UI): ${API_URL}/docs"
  echo "  Ctrl+C para parar tudo."
  echo
}

run_docker() {
  port_free "$API_PORT" || fail "a porta $API_PORT já está em uso. Pare o que estiver nela (talvez a API rodando por fora) e rode de novo."
  echo "==> Subindo front + API via docker compose..."
  print_urls
  open_browser_when_ready
  exec docker compose up --build
}

API_PID=""
FRONT_PID=""
stop_local() {
  if [ -n "$FRONT_PID" ]; then kill "$FRONT_PID" 2>/dev/null || true; fi
  if [ -n "$API_PID" ] && kill -0 "$API_PID" 2>/dev/null; then
    echo "Parando a API..."
    kill "$API_PID" 2>/dev/null || true
    wait "$API_PID" 2>/dev/null || true
  fi
}

run_local() {
  trap stop_local EXIT
  trap 'exit 130' INT TERM

  echo "==> Subindo a API com Python local..."
  if url_up "$API_URL/docs"; then
    echo "    API já está rodando em $API_URL; reaproveitando."
  else
    bash "$API_DIR/start.sh" --local &
    API_PID=$!
    echo "    Aguardando a API ficar pronta (na primeira vez instala as dependências e pode levar alguns minutos)..."
    until url_up "$API_URL/docs"; do
      kill -0 "$API_PID" 2>/dev/null || { API_PID=""; fail "a API não subiu (veja a mensagem acima)."; }
      sleep 1
    done
  fi

  echo "==> Subindo o front-end..."
  print_urls
  open_browser_when_ready
  # Em segundo plano + wait, para o Ctrl+C cair direto no trap que para tudo.
  "$PYTHON" -m http.server "$FRONT_PORT" --bind 127.0.0.1 &
  FRONT_PID=$!
  wait "$FRONT_PID"
}

echo "==> Verificando Python..."
find_python || install_python
echo "    OK: $("$PYTHON" --version) em $PYTHON"

port_free "$FRONT_PORT" || fail "a porta $FRONT_PORT já está em uso. Feche o programa que a usa e rode de novo."

echo "==> Verificando o repositório da API..."
ensure_api_repo
echo "    OK: $API_DIR"

if [ "${1:-}" != "--local" ]; then
  echo "==> Verificando Docker..."
  if ensure_docker; then
    echo "    OK: Docker rodando."
    run_docker
  fi
  echo "    Docker indisponível agora; seguindo com Python local."
fi
run_local
