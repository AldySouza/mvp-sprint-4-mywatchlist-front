# Sobe a aplicacao MyWatchList completa (front + API) num Windows sem nada
# pre-instalado.
#
# Verifica (e instala, se faltar) o Python na versao certa e o Docker, e baixa
# o repositorio da API se ele nao estiver ao lado deste (..\mvp-sprint-4-mywatchlist-api).
# Com o Docker rodando, sobe tudo via docker compose; se o Docker nao ficar
# pronto (ex.: recem-instalado e pedindo reinicializacao), sobe com Python local.
#
#   .\start.ps1           Docker, ou Python local como alternativa
#   .\start.ps1 -Local    direto com Python local, sem Docker
param([switch]$Local)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Set-Location -Path $PSScriptRoot

$frontPort = 3001
$apiPort = 8000  # fixo em app.js (API_BASE_URL)
$apiUrl = "http://localhost:$apiPort"
$frontUrl = "http://localhost:$frontPort"
$apiDir = Join-Path (Split-Path $PSScriptRoot -Parent) "mvp-sprint-4-mywatchlist-api"
$apiRepo = "https://github.com/AldySouza/mvp-sprint-4-mywatchlist-api"
# pydantic 2.9 / fastapi 0.115 (API) tem wheels prontos do Python 3.10 ao 3.13.
$pyVersionCheck = "import sys; sys.exit(0 if (3, 10) <= sys.version_info[:2] <= (3, 13) else 1)"
$dockerDesktop = "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe"
$dockerBin = "$env:ProgramFiles\Docker\Docker\resources\bin"

function Fail($message) {
    Write-Host "Erro: $message" -ForegroundColor Red
    exit 1
}

function Update-SessionPath {
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
    if (Test-Path $dockerBin) { $env:Path += ";$dockerBin" }
}

# ---------------------------------------------------------------- Python

# Retorna o caminho do python.exe se o comando existir e for compativel.
function Resolve-Python([string[]]$cmd) {
    if (-not (Get-Command $cmd[0] -ErrorAction SilentlyContinue)) { return $null }
    $cmdArgs = @($cmd | Select-Object -Skip 1)
    try {
        $exe = & $cmd[0] @cmdArgs -c "$pyVersionCheck; import venv, ensurepip; print(sys.executable)" 2>$null
        if ($LASTEXITCODE -eq 0 -and $exe) { return "$exe".Trim() }
    } catch {}
    return $null
}

function Find-Python {
    $candidates = @(
        @("py", "-3.12"), @("py", "-3.13"), @("py", "-3.11"), @("py", "-3.10"),
        @("python"), @("python3"),
        @("$env:LOCALAPPDATA\Programs\Python\Python312\python.exe"),
        @("$env:ProgramFiles\Python312\python.exe")
    )
    foreach ($c in $candidates) {
        $exe = Resolve-Python $c
        if ($exe) { return $exe }
    }
    return $null
}

function Install-Python {
    Write-Host "    Python 3.10-3.13 nao encontrado. Instalando Python 3.12 (so na primeira vez)..."
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        winget install -e --id Python.Python.3.12 --scope user --silent --accept-package-agreements --accept-source-agreements | Out-Host
    }
    if (-not (Find-Python)) {
        $arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "amd64" }
        $installer = Join-Path $env:TEMP "python-3.12.10-$arch.exe"
        Write-Host "    Baixando instalador do Python..."
        Invoke-WebRequest "https://www.python.org/ftp/python/3.12.10/python-3.12.10-$arch.exe" -OutFile $installer
        Start-Process -Wait -FilePath $installer -ArgumentList "/quiet", "InstallAllUsers=0", "PrependPath=1", "Include_launcher=1"
    }
    Update-SessionPath
    $exe = Find-Python
    if (-not $exe) { Fail "nao consegui instalar o Python. Instale o Python 3.12 em https://www.python.org/downloads/ e rode este script de novo." }
    return $exe
}

# Livre = ninguem escutando nela.
function Test-PortFree([int]$p) {
    $client = [Net.Sockets.TcpClient]::new()
    try { return -not $client.ConnectAsync("127.0.0.1", $p).Wait(1000) } catch { return $true } finally { $client.Dispose() }
}

function Test-UrlUp($url) {
    try { Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 2 | Out-Null; return $true } catch { return $false }
}

# ---------------------------------------------------------------- Docker

function Test-DockerRunning {
    try { docker info *> $null; return ($LASTEXITCODE -eq 0) } catch { return $false }
}

function Install-Docker {
    Write-Host "    Docker nao encontrado. Instalando o Docker Desktop (so na primeira vez; o Windows vai pedir permissao de administrador)..."
    try {
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            winget install -e --id Docker.DockerDesktop --silent --accept-package-agreements --accept-source-agreements | Out-Host
        } else {
            $installer = Join-Path $env:TEMP "DockerDesktopInstaller.exe"
            $arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "amd64" }
            Write-Host "    Baixando instalador do Docker Desktop..."
            Invoke-WebRequest "https://desktop.docker.com/win/main/$arch/Docker%20Desktop%20Installer.exe" -OutFile $installer
            Start-Process -Wait -Verb RunAs -FilePath $installer -ArgumentList "install", "--quiet", "--accept-license"
        }
    } catch {
        return $false
    }
    Update-SessionPath
    return [bool](Get-Command docker -ErrorAction SilentlyContinue)
}

# Retorna $true se, no fim, o Docker estiver instalado e rodando.
function Initialize-Docker {
    Update-SessionPath
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        if (-not (Install-Docker)) { Write-Host "    Nao consegui instalar o Docker."; return $false }
    }
    if (Test-DockerRunning) { return $true }

    Write-Host "    Docker nao esta rodando. Tentando iniciar o Docker Desktop..."
    if (Test-Path $dockerDesktop) { Start-Process $dockerDesktop }
    Write-Host "    Aguardando o Docker iniciar (ate 2 min; na primeira vez, aceite os termos na janela do Docker Desktop)..."
    for ($i = 0; $i -lt 60; $i++) {
        if (Test-DockerRunning) { return $true }
        Start-Sleep -Seconds 2
    }
    Write-Host "    Se o Docker acabou de ser instalado, talvez seja preciso reiniciar o computador."
    return $false
}

# ---------------------------------------------------------------- API

function Initialize-ApiRepo {
    if (Test-Path $apiDir) { return }
    Write-Host "    Nao encontrei $apiDir. Baixando o repositorio da API..."
    if (Get-Command git -ErrorAction SilentlyContinue) {
        git clone "$apiRepo.git" $apiDir
        if ($LASTEXITCODE -ne 0) { Fail "falha ao clonar $apiRepo." }
    } else {
        $zip = Join-Path $env:TEMP "mywatchlist-api.zip"
        $tmp = Join-Path $env:TEMP "mywatchlist-api-src"
        Invoke-WebRequest "$apiRepo/archive/refs/heads/main.zip" -OutFile $zip
        if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
        Expand-Archive $zip -DestinationPath $tmp
        Move-Item (Get-ChildItem $tmp -Directory | Select-Object -First 1).FullName $apiDir
    }
}

# Abre o navegador assim que o front responder (em segundo plano).
function Open-BrowserWhenReady {
    Start-Job -ArgumentList $frontUrl -ScriptBlock {
        param($url)
        for ($i = 0; $i -lt 300; $i++) {
            try { Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 2 | Out-Null; Start-Process $url; return } catch { Start-Sleep -Seconds 1 }
        }
    } | Out-Null
}

function Write-Urls {
    Write-Host ""
    Write-Host "  Aplicacao:        $frontUrl"
    Write-Host "  API (Swagger UI): $apiUrl/docs"
    Write-Host "  Ctrl+C para parar tudo."
    Write-Host ""
}

function Start-WithDocker {
    if (-not (Test-PortFree $apiPort)) { Fail "a porta $apiPort ja esta em uso. Pare o que estiver nela (talvez a API rodando por fora) e rode de novo." }
    Write-Host "==> Subindo front + API via docker compose..."
    Write-Urls
    Open-BrowserWhenReady
    docker compose up --build
    exit $LASTEXITCODE
}

function Start-Local($python) {
    Write-Host "==> Subindo a API com Python local..."
    $apiProc = $null
    try {
        if (Test-UrlUp "$apiUrl/docs") {
            Write-Host "    API ja esta rodando em $apiUrl; reaproveitando."
        } else {
            # A API roda numa janela propria, onde aparecem os logs dela.
            $apiProc = Start-Process powershell -PassThru -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$apiDir\start.ps1`"", "-Local"
            Write-Host "    Aguardando a API ficar pronta (na primeira vez instala as dependencias e pode levar alguns minutos)..."
            while (-not (Test-UrlUp "$apiUrl/docs")) {
                if ($apiProc.HasExited) { $apiProc = $null; Fail "a API nao subiu (veja a janela da API)." }
                Start-Sleep -Seconds 1
            }
        }

        Write-Host "==> Subindo o front-end..."
        Write-Urls
        Open-BrowserWhenReady
        & $python -m http.server $frontPort --bind 127.0.0.1
    } finally {
        if ($apiProc -and -not $apiProc.HasExited) {
            Write-Host "Parando a API..."
            taskkill /PID $apiProc.Id /T /F *> $null
        }
    }
}

Write-Host "==> Verificando Python..."
$python = Find-Python
if (-not $python) { $python = Install-Python }
Write-Host "    OK: $python"

if (-not (Test-PortFree $frontPort)) { Fail "a porta $frontPort ja esta em uso. Feche o programa que a usa e rode de novo." }

Write-Host "==> Verificando o repositorio da API..."
Initialize-ApiRepo
Write-Host "    OK: $apiDir"

if (-not $Local) {
    Write-Host "==> Verificando Docker..."
    if (Initialize-Docker) {
        Write-Host "    OK: Docker rodando."
        Start-WithDocker
    }
    Write-Host "    Docker indisponivel agora; seguindo com Python local."
}
Start-Local $python
