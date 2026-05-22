#Requires -Version 5.1
<#
.SYNOPSIS
    EFIR Digital Signage - Watchdog процесс.
.DESCRIPTION
    Следит за процессом efir.exe и перезапускает его при остановке.
    Запускается Task Scheduler при входе пользователя (см. install-watchdog.ps1).
.PARAMETER AppPath
    Полный путь к efir.exe
.PARAMETER CheckIntervalSeconds
    Интервал проверки в секундах (по умолчанию 10)
.PARAMETER StartupDelaySeconds
    Задержка перед первой проверкой — чтобы дать системе стабилизироваться
#>
param(
    [string]$AppPath            = "C:\Program Files\EFIR\efir.exe",
    [int]   $CheckIntervalSeconds = 10,
    [int]   $StartupDelaySeconds  = 8
)

$ProcessName = [System.IO.Path]::GetFileNameWithoutExtension($AppPath)
$LogDir  = "$env:APPDATA\efir"
$LogPath = "$LogDir\watchdog.log"
$MaxLogBytes = 2MB

# --- Логирование ---
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    try {
        if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
        # Простая ротация: если лог больше 2 МБ — сжать в .old
        if ((Test-Path $LogPath) -and (Get-Item $LogPath).Length -gt $MaxLogBytes) {
            Move-Item -Path $LogPath -Destination "$LogPath.old" -Force
        }
        Add-Content -Path $LogPath -Value $line -Encoding UTF8
    } catch { <# Не падаем если лог недоступен #> }
    Write-Host $line
}

# --- Запуск приложения ---
function Start-Efir {
    try {
        if (-not (Test-Path $AppPath)) {
            Write-Log "Бинарник не найден: $AppPath" "ERROR"
            return
        }
        $proc = Start-Process -FilePath $AppPath -PassThru -ErrorAction Stop
        Write-Log "EFIR запущен (PID $($proc.Id))"
    } catch {
        Write-Log "Не удалось запустить EFIR: $_" "ERROR"
    }
}

# --- Основной цикл ---
Write-Log "Watchdog запущен. Мониторинг: $AppPath (интервал ${CheckIntervalSeconds}s)"

# Задержка старта — даём системе прогрузиться после логина
Start-Sleep -Seconds $StartupDelaySeconds

# Первый запуск если процесс ещё не работает
$running = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue
if (-not $running) {
    Write-Log "EFIR не запущен при старте watchdog — запускаем"
    Start-Efir
    Start-Sleep -Seconds 3
}

$consecutiveFailures = 0
$maxConsecutiveFailures = 10  # После 10 неудач подряд — ждать 5 минут

while ($true) {
    Start-Sleep -Seconds $CheckIntervalSeconds

    $procs = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue
    if (-not $procs) {
        $consecutiveFailures++
        Write-Log "EFIR не найден (попытка $consecutiveFailures)" "WARN"

        if ($consecutiveFailures -ge $maxConsecutiveFailures) {
            Write-Log "Слишком много неудачных перезапусков — пауза 5 минут" "ERROR"
            Start-Sleep -Seconds 300
            $consecutiveFailures = 0
        }

        Start-Efir
    } else {
        if ($consecutiveFailures -gt 0) {
            Write-Log "EFIR снова работает (PID $($procs[0].Id))"
        }
        $consecutiveFailures = 0
    }
}
