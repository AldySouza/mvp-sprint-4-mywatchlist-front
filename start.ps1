$ErrorActionPreference = "Stop"

Set-Location -Path $PSScriptRoot

function Wait-ForDocker {
    $tries = 0
    while ($true) {
        docker info *> $null
        if ($LASTEXITCODE -eq 0) { return }
        $tries++
        if ($tries -gt 30) {
            Write-Error "Docker nao respondeu a tempo. Abra o Docker Desktop manualmente e rode este script de novo."
            exit 1
        }
        Start-Sleep -Seconds 2
    }
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Error "Docker nao encontrado. Instale em https://docs.docker.com/get-docker/ e rode este script de novo."
    exit 1
}

docker info *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Docker nao esta rodando. Tentando iniciar o Docker Desktop..."
    $dockerDesktop = "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe"
    if (Test-Path $dockerDesktop) {
        Start-Process $dockerDesktop
    }
    Write-Host "Aguardando o Docker iniciar (pode levar ate 1 minuto)..."
    Wait-ForDocker
}

if (-not (Test-Path "..\mywatchlist-api")) {
    Write-Warning "Nao encontrei ..\mywatchlist-api. Clone os dois repositorios no mesmo diretorio pai."
}

Write-Host "Docker pronto. Subindo mywatchlist-front + mywatchlist-api via docker compose..."
Write-Host "Front-end: http://localhost:3001"
Write-Host "API (Swagger UI): http://localhost:8000/docs"
docker compose up --build
