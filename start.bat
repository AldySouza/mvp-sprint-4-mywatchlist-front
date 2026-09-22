@echo off
setlocal enabledelayedexpansion

cd /d "%~dp0"

where docker >nul 2>nul
if errorlevel 1 (
    echo Docker nao encontrado. Instale em https://docs.docker.com/get-docker/ e rode este script de novo.
    exit /b 1
)

docker info >nul 2>nul
if errorlevel 1 (
    echo Docker nao esta rodando. Tentando iniciar o Docker Desktop...
    if exist "%ProgramFiles%\Docker\Docker\Docker Desktop.exe" (
        start "" "%ProgramFiles%\Docker\Docker\Docker Desktop.exe"
    )
    echo Aguardando o Docker iniciar ^(pode levar ate 1 minuto^)...
    set tries=0
    :waitloop
    timeout /t 2 >nul
    set /a tries+=1
    docker info >nul 2>nul
    if not errorlevel 1 goto ready
    if !tries! GEQ 30 (
        echo Docker nao respondeu a tempo. Abra o Docker Desktop manualmente e rode este script de novo.
        exit /b 1
    )
    goto waitloop
)

:ready
if not exist "..\mywatchlist-api\" (
    echo Aviso: nao encontrei ..\mywatchlist-api. Clone os dois repositorios no mesmo diretorio pai.
)

echo Docker pronto. Subindo mywatchlist-front + mywatchlist-api via docker compose...
echo Front-end: http://localhost:3001
echo API (Swagger UI): http://localhost:8000/docs
docker compose up --build
