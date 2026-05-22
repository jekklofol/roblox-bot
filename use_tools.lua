local V                     = "v3.0.0-supabase"
local PLACE_ID              = 920587237
local MIN_PLAYERS_PREFERRED = 5
local MAX_PLAYERS_ALLOWED   = 100
local SEARCH_TIMEOUT        = 60
local TELEPORT_COOLDOWN     = 15
local SCRIPT_URL            = "https://raw.githubusercontent.com/jekklofol/roblox-bot/refs/heads/main/use_tools.lua"

-- cache-bust для tools.lua, иначе GitHub raw отдаёт устаревшую версию
local Tools = loadstring(game:HttpGet(
    "https://raw.githubusercontent.com/jekklofol/roblox-bot/main/tools.lua?t=" .. tick()
))()

if _G.BotRunning then
    warn("Скрипт уже запущен!")
    return
end
_G.BotRunning = true

local Players = game:GetService("Players")
local player  = Players.LocalPlayer

Tools.setup({
    placeId             = PLACE_ID,
    minPlayersPreferred = MIN_PLAYERS_PREFERRED,
    maxPlayersAllowed   = MAX_PLAYERS_ALLOWED,
    searchTimeout       = SEARCH_TIMEOUT,
    teleportCooldown    = TELEPORT_COOLDOWN,
    scriptUrl           = SCRIPT_URL,
})

-- ============================================================
-- Bootstrap
-- ============================================================
Tools.initBot(V)
Tools.startSession()
Tools.startHeartbeat(45)
Tools.startCommandLoop(5)

-- стартовый snapshot, чтобы видеть состояние при заходе на сервер
pcall(Tools.logSystemSnapshot, "boot")

-- удалённый конфиг → переменные бота
local minOverride = tonumber(Tools.getRemoteConfigValue("min_players_preferred"))
if minOverride then Tools.minPlayersPreferred = minOverride end

local speedOverride = tonumber(Tools.getRemoteConfigValue("chat_speed_multiplier"))
if speedOverride and speedOverride > 0 then Tools.chatSpeedMul = speedOverride end

Tools.autoReconnect()

-- ============================================================
-- Main loop body (защищён глобальным xpcall)
-- ============================================================
local function runBot()
    if not Tools.getBotState().running then
        Tools.logWarning("runBot: botState.running=false, выхожу",
            { category = "BOT" })
        return
    end
    Tools.enabled = true
    Tools.logInfo("Скрипт запущен", { category = "BOT", version = V })

    Tools.connectChatListener()
    Tools.preloadMessages(true)

    Tools.randomDelay(2, 5)

    if Tools.waitForPlayButton(20) then
        Tools.randomDelay(1, 3)
        Tools.clickPlayButton()
    else
        Tools.logWarning("PlayButton не появился — пропускаю шаг",
            { category = "BOT" })
    end

    if Tools.waitForAdoptionIslandButton(20) then
        Tools.randomDelay(1, 3)
        local ok = Tools.clickAdoptionIslandButton()
        if not ok then
            Tools.logWarning("Не удалось кликнуть Adoption Island",
                { category = "BOT" })
        end
    end

    Tools.randomDelay(4, 8)

    -- casual
    local casual = Tools.getCasualMessage()
    Tools.sendChat(casual)

    Tools.randomDelay(5, 10)

    -- реклама
    local ad = Tools.getAdMessage()
    if ad then
        Tools.sendChat(ad.message)
        local filtered = Tools.checkAndDeactivateIfFiltered(ad.id, 2)
        if not filtered then
            Tools.markAdMessageUsed(ad.id, ad.cooldown_minutes or 60)
        end
    else
        Tools.logWarning("Нет доступной рекламы — fallback",
            { category = "AD" })
        Tools.sendChat("RBLX . PW - sell you pets for real money")
    end

    Tools.randomDelay(2, 5)
    Tools.endSession()
    Tools.serverHop()
end

-- ============================================================
-- Watchdog: если runBot завис — телепорт обратно на главный
-- (запускается параллельно; убивается телепортом)
-- ============================================================
task.spawn(function()
    task.wait(300) -- 5 минут
    if Tools.isEnabled() then
        Tools.logCritical("Watchdog: 5 мин без serverHop, форс-телепорт", {
            category = "WATCHDOG",
        })
        pcall(Tools._flushLogs)
        for _ = 1, 3 do
            pcall(Tools.serverHop)
            task.wait(15)
        end
        pcall(function()
            game:GetService("TeleportService"):Teleport(PLACE_ID, player)
        end)
    end
end)

-- ============================================================
-- Глобальный xpcall — любая ошибка логируется и шлёт rejoin
-- ============================================================
task.spawn(function()
    local ok, err = xpcall(runBot, function(e)
        return tostring(e) .. "\n" .. debug.traceback("", 2)
    end)
    if not ok then
        Tools.logCritical("runBot упал с исключением", {
            category = "EXCEPTION",
            error    = tostring(err),
        })
        pcall(Tools._flushLogs)
        task.wait(3)
        pcall(Tools.serverHop)
    end
end)
