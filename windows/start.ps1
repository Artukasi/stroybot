# Запуск СтройБота на компьютере с Windows. Запускается двойным щелчком по start-bot.bat.
# 1) ставит Python-библиотеки, 2) при первом запуске спрашивает токен бота и ключ kie.ai,
# 3) открывает бесплатный https-адрес через Cloudflare (для Mini App и iPhone-сканера),
# 4) запускает бота и перезапускает его, если он упал.
param(
    [string]$Root = (Split-Path -Parent $PSScriptRoot),
    [string]$Python = "",
    [string]$Cloudflared = "",
    [switch]$NoTunnel,
    [switch]$SetupOnly
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8"
Set-Location $Root
$IsWin = [Environment]::OSVersion.Platform -eq "Win32NT"
# Telegram и GitHub принимают только TLS 1.2+, а старый Windows PowerShell по умолчанию может начать с TLS 1.0
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

function Say([string]$text, [string]$color = "Gray") { Write-Host $text -ForegroundColor $color }
function Step([string]$text) { Write-Host ""; Write-Host "== $text" -ForegroundColor Yellow }

# ---------- настройки из .env ----------

function Read-Env([string]$path) {
    $vals = @{}
    if (Test-Path $path) {
        foreach ($line in [IO.File]::ReadAllLines($path)) {
            if ($line -match '^\s*([A-Z_]+)\s*=(.*)$') { $vals[$Matches[1]] = $Matches[2].Trim() }
        }
    }
    return $vals
}

function Write-Env([string]$path, [hashtable]$set) {
    # Берём .env.example как шаблон (там подсказки), подставляем значения, пишем UTF-8 без BOM.
    $src = if (Test-Path $path) { $path } else { Join-Path $Root ".env.example" }
    $lines = [Collections.Generic.List[string]]::new()
    $done = @{}
    foreach ($line in [IO.File]::ReadAllLines($src)) {
        if ($line -match '^\s*([A-Z_]+)\s*=' -and $set.ContainsKey($Matches[1])) {
            $key = $Matches[1]; $lines.Add("$key=$($set[$key])"); $done[$key] = $true
        } else { $lines.Add($line) }
    }
    foreach ($key in $set.Keys) { if (-not $done[$key]) { $lines.Add("$key=$($set[$key])") } }
    [IO.File]::WriteAllLines($path, $lines, [Text.UTF8Encoding]::new($false))
}

function Get-BotInfo([string]$token) {
    try {
        $r = Invoke-RestMethod -Uri "https://api.telegram.org/bot$token/getMe" -TimeoutSec 20
        if ($r.ok) { return $r.result }
    } catch { }
    return $null
}

function Wait-AdminId([string]$token, [string]$username) {
    Say "Откройте в Telegram вашего бота @$username и нажмите «Старт» (или напишите ему любое слово)." "Cyan"
    Say "Жду сообщение до 3 минут..."
    $until = (Get-Date).AddMinutes(3)
    while ((Get-Date) -lt $until) {
        try {
            $r = Invoke-RestMethod -Uri "https://api.telegram.org/bot$token/getUpdates?timeout=20" -TimeoutSec 30
            foreach ($u in $r.result) {
                if ($u.message -and $u.message.from) { return [string]$u.message.from.id }
            }
        } catch { Start-Sleep -Seconds 3 }
    }
    return ""
}

function Setup-Env {
    $envPath = Join-Path $Root ".env"
    $cur = Read-Env $envPath
    $set = @{}

    $token = $cur["BOT_TOKEN"]
    $bot = $null
    if ($token -and $token -notlike "123456:*") { $bot = Get-BotInfo $token }
    while (-not $bot) {
        Step "Токен бота"
        Say "В Telegram откройте @BotFather, отправьте /newbot, придумайте имя и адрес бота (должен кончаться на bot)."
        Say "BotFather пришлёт токен вида 1234567890:AAH... Скопируйте его и вставьте сюда (правый щелчок мыши = вставить)."
        $token = (Read-Host "Токен").Trim()
        $bot = Get-BotInfo $token
        if (-not $bot) { Say "Telegram не принял этот токен. Проверьте, что скопировали его целиком." "Red" }
    }
    $set["BOT_TOKEN"] = $token
    Say "Бот найден: @$($bot.username)" "Green"

    $key = $cur["KIE_API_KEY"]
    if (-not $key -or $key -eq "your_kie_key") {
        Step "Ключ kie.ai"
        Say "Зайдите на https://kie.ai, войдите через Google, откройте https://kie.ai/api-key и нажмите создать ключ."
        Say "Чтобы ИИ работал, на балансе kie.ai должны быть кредиты (пополняется там же)."
        while (-not $key -or $key -eq "your_kie_key") { $key = (Read-Host "Ключ kie.ai").Trim() }
    }
    $set["KIE_API_KEY"] = $key

    $admin = $cur["ADMIN_IDS"]
    if (-not $admin -or $admin -eq "123456789") {
        Step "Ваш Telegram ID (для админ-команд)"
        $admin = Wait-AdminId $token $bot.username
        if ($admin) { Say "Ваш ID: $admin" "Green" }
        else {
            Say "Сообщение не пришло. Узнать ID можно у @userinfobot." "Red"
            $admin = (Read-Host "Ваш ID (цифры, можно оставить пустым)").Trim()
        }
    }
    $set["ADMIN_IDS"] = $admin

    Write-Env $envPath $set
    Say "Настройки сохранены в файл .env (он остаётся только на этом компьютере)." "Green"
}

# ---------- Python ----------

function Find-Python {
    if ($Python) { return $Python }
    foreach ($cand in @(@("py", "-3"), @("python"), @("python3"))) {
        try {
            $args_ = @($cand | Select-Object -Skip 1) + @("-c", "import sys; print(sys.version_info >= (3, 10))")
            $out = & $cand[0] @args_ 2>$null
            if ($LASTEXITCODE -eq 0 -and "$out".Trim() -eq "True") { return ($cand -join " ") }
        } catch { }
    }
    return ""
}

function Setup-Python {
    $venvPy = if ($IsWin) { Join-Path $Root ".venv\Scripts\python.exe" } else { Join-Path $Root ".venv/bin/python" }
    if (-not (Test-Path $venvPy)) {
        Step "Готовлю Python"
        $py = Find-Python
        if (-not $py -and $IsWin) {
            Say "Python не найден, ставлю его через winget (понадобится подтвердить)..."
            winget install -e --id Python.Python.3.12 --accept-source-agreements --accept-package-agreements
            $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                        [Environment]::GetEnvironmentVariable("Path", "User")
            $py = Find-Python
        }
        if (-not $py) {
            Say "Не получилось найти Python 3.10+. Скачайте его с https://www.python.org/downloads/ ," "Red"
            Say "при установке поставьте галочку «Add python.exe to PATH», затем снова запустите start-bot.bat." "Red"
            exit 1
        }
        $parts = $py -split " "
        & $parts[0] @($parts | Select-Object -Skip 1) -m venv (Join-Path $Root ".venv")
        if ($LASTEXITCODE -ne 0) { Say "Не удалось создать окружение Python." "Red"; exit 1 }
    }
    # Ставим библиотеки, только если список поменялся
    $req = Join-Path $Root "requirements.txt"
    $stamp = Join-Path (Join-Path $Root ".venv") "requirements.stamp"
    $hash = (Get-FileHash $req -Algorithm SHA256).Hash
    if (-not (Test-Path $stamp) -or (Get-Content $stamp -Raw).Trim() -ne $hash) {
        Step "Ставлю библиотеки (один раз, пару минут)"
        & $venvPy -m pip install --disable-pip-version-check -q -r $req
        if ($LASTEXITCODE -ne 0) { Say "Библиотеки не поставились, проверьте интернет и запустите ещё раз." "Red"; exit 1 }
        Set-Content -Path $stamp -Value $hash
    }
    return $venvPy
}

# ---------- Cloudflare: бесплатный https-адрес ----------

function Get-Cloudflared {
    if ($Cloudflared) { return $Cloudflared }
    $exe = Join-Path $PSScriptRoot "cloudflared.exe"
    if (-not (Test-Path $exe)) {
        Step "Скачиваю cloudflared (бесплатная программа Cloudflare для https-адреса)"
        $url = "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe"
        Invoke-WebRequest -Uri $url -OutFile $exe -UseBasicParsing
    }
    return $exe
}

function Find-TunnelUrl([string]$logPath) {
    if (-not (Test-Path $logPath)) { return "" }
    $text = Get-Content $logPath -Raw -ErrorAction SilentlyContinue
    if ($text -match '(https://[a-z0-9-]+\.trycloudflare\.com)') { return $Matches[1] }
    return ""
}

function Start-Tunnel([int]$port) {
    $exe = Get-Cloudflared
    $log = Join-Path $PSScriptRoot "cloudflared.log"
    Remove-Item $log -ErrorAction SilentlyContinue
    $p = Start-Process -FilePath $exe -PassThru -WindowStyle Hidden `
        -ArgumentList @("tunnel", "--no-autoupdate", "--url", "http://127.0.0.1:$port", "--logfile", "`"$log`"")
    Say "Жду адрес от Cloudflare..."
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Seconds 1
        $url = Find-TunnelUrl $log
        if ($url) { return @{ Process = $p; Url = $url } }
        if ($p.HasExited) { break }
    }
    return @{ Process = $p; Url = "" }
}

# ---------- запуск ----------
# При подключении через точку (. .\start.ps1) только объявляем функции — так их проверяют тесты.
if ($MyInvocation.InvocationName -eq ".") { return }

Say "СтройБот: запуск" "Yellow"
if (-not (Test-Path (Join-Path $Root "bot\__main__.py")) -and -not (Test-Path (Join-Path $Root "bot/__main__.py"))) {
    Say "Не вижу папку bot. Положите папку windows рядом с папкой bot (в корне проекта)." "Red"; exit 1
}
Setup-Env
$py = Setup-Python

$tunnel = $null
if (-not $NoTunnel) {
    $cfg = Read-Env (Join-Path $Root ".env")
    $port = if ($cfg["WEB_PORT"]) { [int]$cfg["WEB_PORT"] } else { 8080 }
    Step "Открываю https-адрес для приложения"
    try { $tunnel = Start-Tunnel $port } catch { Say "Cloudflare не запустился: $($_.Exception.Message)" "Red" }
    if ($tunnel -and $tunnel.Url) {
        $env:WEBAPP_URL = $tunnel.Url
        Say "Адрес: $($tunnel.Url)  (после каждого перезапуска он новый, бот обновит кнопку сам)" "Green"
    } else {
        Say "Адрес не получен: бот заработает без кнопки «Приложение». Запустите start-bot.bat позже ещё раз." "Red"
    }
}

Step "Проверяю ключи"
& $py -m bot.check
if ($LASTEXITCODE -ne 0) {
    Say "Что-то не так с ключами (см. строки с [!!]). Исправить можно в файле .env блокнотом." "Red"
}
if ($SetupOnly) { exit $LASTEXITCODE }

Step "Бот работает. Не закрывайте это окно и не отправляйте компьютер в сон. Остановить: Ctrl+C"
try {
    while ($true) {
        & $py -m bot
        Say "Бот остановился, перезапускаю через 10 секунд (Ctrl+C, чтобы выйти)..." "Red"
        Start-Sleep -Seconds 10
    }
} finally {
    if ($tunnel -and $tunnel.Process -and -not $tunnel.Process.HasExited) { Stop-Process -Id $tunnel.Process.Id -Force }
}
