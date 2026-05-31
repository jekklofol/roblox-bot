# ============================================================
# Reklamshiki Watchdog
#   Следит за heartbeat ботов в Supabase. Если бот перестал
#   слать heartbeat (упал процесс/эмулятор) — помечает offline
#   и запускает команду перезапуска для этого аккаунта.
#
#   Почему так: боты умирают мгновенно вместе с процессом клиента
#   (краш/OOM эмулятора) — Lua-watchdog в этом случае бессилен,
#   нужен внешний наблюдатель на уровне ОС.
#
#   Запуск:  powershell -ExecutionPolicy Bypass -File watchdog.ps1
# ============================================================

# ---- КОНФИГ ----
$SupabaseUrl   = "https://tzqzynajdeyrahzpzsim.supabase.co/rest/v1"
$SupabaseKey   = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InR6cXp5bmFqZGV5cmFoenB6c2ltIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzc4Mzk1MTMsImV4cCI6MjA5MzQxNTUxM30.DohPVX1ZwHFi0R4xNKx5ntZRBgoyq1iWnNlU_6FaSRs"

$CheckIntervalSec = 60     # как часто проверять
$DeadThresholdSec = 180    # heartbeat старше этого = бот считается мёртвым (heartbeat шлётся каждые 45с)
$RestartCooldownSec = 300  # не перезапускать один аккаунт чаще, чем раз в N секунд
$AccountsFile = Join-Path $PSScriptRoot "accounts.json"
$LogFile      = Join-Path $PSScriptRoot "watchdog.log"

# ---- ВСПОМОГАТЕЛЬНОЕ ----
function Write-Log($msg) {
    $line = "{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -Encoding utf8
}

$headers = @{
    "apikey"        = $SupabaseKey
    "Authorization" = "Bearer $SupabaseKey"
    "Content-Type"  = "application/json"
}

# accounts.json — маппинг username -> команда запуска этого аккаунта.
# Пример (заполнить под свою схему запуска: RAMP / deep-link / эмулятор):
# {
#   "Vortas10":  "C:\\RAMP\\rbxalt.exe launch --account Vortas10",
#   "Onyxez15":  "roblox-player:1+launchmode:play+placeId:920587237"
# }
# Если username нет в файле — watchdog только пометит offline и залогирует (без рестарта).
function Load-Accounts {
    if (Test-Path $AccountsFile) {
        try { return (Get-Content $AccountsFile -Raw -Encoding utf8 | ConvertFrom-Json) }
        catch { Write-Log "accounts.json повреждён: $_"; return $null }
    }
    return $null
}

$lastRestart = @{}  # username -> [datetime] последнего рестарта

function Restart-Bot($username, $accounts) {
    # анти-флуд: не перезапускаем чаще RestartCooldownSec
    if ($lastRestart.ContainsKey($username)) {
        $since = (Get-Date) - $lastRestart[$username]
        if ($since.TotalSeconds -lt $RestartCooldownSec) {
            Write-Log "  [$username] рестарт пропущен (cooldown, прошло $([int]$since.TotalSeconds)с)"
            return
        }
    }

    $cmd = $null
    if ($accounts -and $accounts.PSObject.Properties.Name -contains $username) {
        $cmd = $accounts.$username
    }

    if (-not $cmd) {
        Write-Log "  [$username] УПАЛ — команда запуска не задана в accounts.json (только пометил offline)"
        return
    }

    Write-Log "  [$username] УПАЛ — перезапускаю: $cmd"
    try {
        # запуск через cmd, чтобы поддержать и .exe с аргументами, и deep-link (roblox://...)
        Start-Process -FilePath "cmd.exe" -ArgumentList "/c", $cmd -WindowStyle Hidden
        $lastRestart[$username] = Get-Date
    } catch {
        Write-Log "  [$username] ОШИБКА запуска: $_"
    }
}

function Mark-Offline($botId) {
    try {
        $uri = "$SupabaseUrl/bots?id=eq.$botId"
        $h = $headers.Clone(); $h["Prefer"] = "return=minimal"
        Invoke-RestMethod -Uri $uri -Method Patch -Headers $h -Body '{"status":"offline"}' | Out-Null
    } catch { Write-Log "  Mark-Offline($botId) ошибка: $_" }
}

# ---- ОСНОВНОЙ ЦИКЛ ----
Write-Log "=== Watchdog запущен. interval=$CheckIntervalSec dead=$DeadThresholdSec ==="
while ($true) {
    try {
        $accounts = Load-Accounts
        $uri = "$SupabaseUrl/bots?select=id,username,status,last_seen"
        $bots = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers

        $now = (Get-Date).ToUniversalTime()
        $alive = 0; $dead = 0
        foreach ($b in $bots) {
            if (-not $b.last_seen) { continue }
            $ls = ([datetimeoffset]$b.last_seen).UtcDateTime
            $ageSec = ($now - $ls).TotalSeconds

            if ($b.status -eq "online" -and $ageSec -gt $DeadThresholdSec) {
                $dead++
                Mark-Offline $b.id
                Restart-Bot $b.username $accounts
            } elseif ($ageSec -le $DeadThresholdSec) {
                $alive++
            }
        }
        Write-Log "Проверка: живых=$alive упавших=$dead всего=$($bots.Count)"
    } catch {
        Write-Log "Ошибка цикла: $_"
    }
    Start-Sleep -Seconds $CheckIntervalSec
}
