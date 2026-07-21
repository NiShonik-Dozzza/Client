#Requires -Version 5.1
<#
.SYNOPSIS
    Устанавливает EFIR watchdog как задачу Windows Task Scheduler.
.DESCRIPTION
    Регистрирует две задачи:
      1. EFIR-Watchdog — запускает watchdog.ps1 при логине пользователя.
         Watchdog следит за efir.exe и перезапускает его при падении.
      2. Опционально: efir-autostart — прямой запуск efir.exe при старте системы.

    Запускать с правами администратора:
      Set-ExecutionPolicy Bypass -Scope Process -Force
      .\install-watchdog.ps1 -AppPath "C:\Program Files\EFIR\efir.exe"
.PARAMETER AppPath
    Полный путь к efir.exe
.PARAMETER WatchdogScriptPath
    Путь к watchdog.ps1 (по умолчанию — рядом с этим скриптом)
.PARAMETER TaskUser
    Пользователь под которым запускать (по умолчанию — текущий)
#>
param(
    [string]$AppPath           = "C:\Program Files\EFIR\efir.exe",
    [string]$WatchdogScriptPath = "",
    [string]$TaskUser          = $env:USERNAME,
    # Тихий режим для установщика (в т.ч. при автообновлении): без вопросов.
    [switch]$Silent
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Путь к watchdog.ps1 по умолчанию — папка рядом с этим скриптом
if (-not $WatchdogScriptPath) {
    $WatchdogScriptPath = Join-Path $PSScriptRoot "watchdog.ps1"
}

# --- Проверки ---
if (-not (Test-Path $AppPath)) {
    Write-Error "Бинарник не найден: $AppPath"
}
if (-not (Test-Path $WatchdogScriptPath)) {
    Write-Error "watchdog.ps1 не найден: $WatchdogScriptPath"
}

# Права администратора НЕ нужны: задача регистрируется на текущего пользователя
# и запускается от него же. Это и позволяет обновлять клиента без UAC.

# --- Регистрация задачи watchdog ---
$watchdogTaskName = "EFIR-Watchdog"
$psExe = (Get-Command powershell.exe).Source

# Аргументы запуска watchdog скрытым (без консоли)
$watchdogArgs = "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass " +
    "-File `"$WatchdogScriptPath`" " +
    "-AppPath `"$AppPath`""

Write-Host "Регистрация задачи: $watchdogTaskName"

# Удалить старую задачу если есть
Unregister-ScheduledTask -TaskName $watchdogTaskName -Confirm:$false -ErrorAction SilentlyContinue

$action  = New-ScheduledTaskAction -Execute $psExe -Argument $watchdogArgs
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $TaskUser
$settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit (New-TimeSpan -Hours 0) `
    -RestartCount 5 `
    -RestartInterval (New-TimeSpan -Minutes 2) `
    -StartWhenAvailable `
    -RunOnlyIfNetworkAvailable:$false

$principal = New-ScheduledTaskPrincipal `
    -UserId $TaskUser `
    -LogonType Interactive `
    -RunLevel Limited

Register-ScheduledTask `
    -TaskName  $watchdogTaskName `
    -Action    $action `
    -Trigger   $trigger `
    -Settings  $settings `
    -Principal $principal `
    -Force | Out-Null

Write-Host "OK: Задача '$watchdogTaskName' зарегистрирована."
Write-Host ""
Write-Host "Полезные команды:"
Write-Host "  Запустить сейчас:  Start-ScheduledTask -TaskName '$watchdogTaskName'"
Write-Host "  Статус:            Get-ScheduledTask   -TaskName '$watchdogTaskName' | Select-Object State"
Write-Host "  Удалить:           Unregister-ScheduledTask -TaskName '$watchdogTaskName' -Confirm:`$false"
Write-Host "  Логи watchdog:     `$env:APPDATA\efir\watchdog.log"
Write-Host ""

# Стартовать задачу немедленно. В тихом режиме — без вопросов: этот скрипт
# вызывается установщиком, в том числе при автообновлении, где спросить некого.
if ($Silent) {
    Start-ScheduledTask -TaskName $watchdogTaskName
    Write-Host "Watchdog запущен."
} else {
    $start = Read-Host "Запустить watchdog прямо сейчас? (y/n)"
    if ($start -eq 'y') {
        Start-ScheduledTask -TaskName $watchdogTaskName
        Write-Host "Watchdog запущен."
    }
}
