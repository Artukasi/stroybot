# Автозапуск СтройБота вместе с Windows: бот работает в фоне, окно держать не нужно.
# Включить: autostart-on.bat, выключить: autostart-off.bat. Права администратора не нужны.
param([switch]$Off)
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$name = "StroyBot"
$root = Split-Path -Parent $PSScriptRoot
$script = Join-Path $PSScriptRoot "start.ps1"

function Stop-Bot {
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.CommandLine -and (($_.CommandLine -like "*windows\start.ps1*") -or
            ($_.Name -like "python*" -and $_.CommandLine -like "*-m bot*" -and $_.ExecutablePath -like "$root*") -or
            ($_.Name -like "cloudflared*"))
    } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

if ($Off) {
    Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
    Stop-Bot
    Write-Host "Автозапуск выключен, бот остановлен. Запустить вручную: start-bot.bat" -ForegroundColor Yellow
    exit 0
}

if (-not (Test-Path (Join-Path $root ".env"))) {
    Write-Host "Сначала один раз запустите start-bot.bat и введите ключи, потом включайте автозапуск." -ForegroundColor Red
    exit 1
}

$action = New-ScheduledTaskAction -Execute "powershell.exe" -WorkingDirectory $root `
    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`" -Background"
$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
    -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
    -Description "СтройБот: Telegram-бот и адрес Cloudflare для приложения" -Force | Out-Null

# окно ручного запуска больше не нужно: закрываем его и запускаем фоновую копию
Stop-Bot
Start-Sleep -Seconds 2
Start-ScheduledTask -TaskName $name
Write-Host "Готово: бот работает в фоне и сам запускается при входе в Windows." -ForegroundColor Green
Write-Host "Журнал: windows\logs\bot.log. Выключить: autostart-off.bat" -ForegroundColor Green
