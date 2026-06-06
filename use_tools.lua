local V                     = "v3.13.0-reach"
local PLACE_ID              = 920587237
local MIN_PLAYERS_PREFERRED = 5
local MAX_PLAYERS_ALLOWED   = 100
local SEARCH_TIMEOUT        = 60
local TELEPORT_COOLDOWN     = 15
local MAX_SERVER_TIME_SEC   = 360   -- жёсткий cap на время на одном сервере
local MIN_PLAYERS_FOR_AD    = 3     -- если меньше — реклама бесполезна, сразу hop
local TARGET_DWELL_MIN      = 150   -- минимально сидим на сервере (реже телепорты = меньше крашей/детекта)
local TARGET_DWELL_MAX      = 260   -- максимально (до hard cap)
local AD_GAP_MIN            = 45    -- интервал между рекламами в рамках одного захода
local AD_GAP_MAX            = 80
local SCRIPT_URL            = "https://raw.githubusercontent.com/jekklofol/roblox-bot/refs/heads/main/use_tools.lua"

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
-- Bootstrap (initBot первым делом — чтобы version и bot_id обновились ДО reroll'ов)
-- ============================================================
Tools.initBot(V)
Tools.startSession()

-- расширенная проверка: после initBot спрашиваем у Supabase, не сидит ли другой бот тут
if Tools.checkServerSharedWithOtherBot(SCRIPT_URL) then
    return
end

Tools.startHeartbeat(45)
Tools.startCommandLoop(5)
Tools.startPoolRefresher(PLACE_ID, 90)

pcall(Tools.logSystemSnapshot, "boot")

local minOverride = tonumber(Tools.getRemoteConfigValue("min_players_preferred"))
if minOverride then Tools.minPlayersPreferred = minOverride end

local speedOverride = tonumber(Tools.getRemoteConfigValue("chat_speed_multiplier"))
if speedOverride and speedOverride > 0 then Tools.chatSpeedMul = speedOverride end

Tools.autoReconnect()

-- ============================================================
-- Main flow
-- ============================================================
local serverStartTick = tick()

local function runBot()
    if not Tools.getBotState().running then
        Tools.logWarning("runBot: botState.running=false, выхожу", { category = "BOT" })
        return
    end
    Tools.enabled = true
    Tools.logInfo("Скрипт запущен", { category = "BOT", version = V })

    Tools.connectChatListener()
    Tools.preloadMessages(true)

    Tools.randomDelay(2, 5)

    -- проверка игроков ДО кликов: если сервер почти пустой — сразу hop, не тратим время
    local playerCount = #Players:GetPlayers()
    if playerCount < MIN_PLAYERS_FOR_AD then
        Tools.logInfo("Слишком мало игроков на сервере, hop", {
            category = "BOT", players = playerCount, min = MIN_PLAYERS_FOR_AD,
        })
        Tools.endSession()
        Tools.fastServerHop()
        return
    end

    if Tools.waitForPlayButton(20) then
        Tools.randomDelay(1, 3)
        Tools.clickPlayButton()
    else
        Tools.logWarning("PlayButton не появился — пропускаю шаг", { category = "BOT" })
    end

    -- Adoption Island не на каждом сервере — короткий таймаут, шаг некритичный
    if Tools.waitForAdoptionIslandButton(6) then
        Tools.randomDelay(1, 3)
        local ok = Tools.clickAdoptionIslandButton()
        if not ok then
            Tools.logWarning("Не удалось кликнуть Adoption Island", { category = "BOT" })
        end
    end

    Tools.randomDelay(4, 8)

    local casual = Tools.getCasualMessage()
    Tools.sendChat(casual)

    Tools.randomDelay(5, 10)

    -- отправка одного объявления через SendAsync (точный результат фильтрации)
    local function sendOneAd()
        local ad = Tools.getAdMessage()
        if not ad then
            Tools.logWarning("Нет доступной рекламы — fallback", { category = "AD" })
            Tools.sendChat("RBLX . PW - sell you pets for real money")
            return
        end
        local result = Tools.sendChatAsync(ad.message)
        if result == "error" then
            -- SendAsync недоступен в этом executor → печатаем, реклама всё равно уходит
            Tools.sendChat(ad.message)
            Tools.markAdMessageUsed(ad.id, ad.cooldown_minutes or 60)
        elseif result == "censored" then
            -- контент триггерит фильтр → длинный cooldown, чтобы реже его доставать
            Tools.markAdMessageUsed(ad.id, Tools.filteredCooldownMinutes)
        else
            -- ok / flood / blocked → обычный cooldown (контент сам по себе нормальный)
            Tools.markAdMessageUsed(ad.id, ad.cooldown_minutes or 60)
        end
    end

    -- держимся на сервере TARGET_DWELL секунд, шлём несколько реклам с паузами.
    -- реже телепортимся → меньше нагрузка/пики памяти/teleport-флаги, больше реклам за заход.
    local dwellTarget = TARGET_DWELL_MIN + math.random() * (TARGET_DWELL_MAX - TARGET_DWELL_MIN)
    sendOneAd()
    while Tools.getBotState().running and (tick() - serverStartTick) < dwellTarget do
        Tools.randomDelay(AD_GAP_MIN, AD_GAP_MAX)
        if not Tools.getBotState().running then break end
        if #Players:GetPlayers() < MIN_PLAYERS_FOR_AD then break end
        sendOneAd()
    end

    Tools.randomDelay(2, 5)
    pcall(function() Tools.recordReach(game.JobId) end)
    Tools.logInfo("Цикл завершён, hop", {
        category        = "BOT",
        time_on_server  = math.floor(tick() - serverStartTick),
    })
    Tools.endSession()
    Tools.fastServerHop()
end

-- ============================================================
-- Hard cap: безусловный hop после MAX_SERVER_TIME_SEC секунд
-- никакая ошибка/зависание не оставит бота на сервере дольше
-- ============================================================
task.spawn(function()
    task.wait(MAX_SERVER_TIME_SEC)
    Tools.logWarning("Hard cap: " .. MAX_SERVER_TIME_SEC .. "с истекли, форс-hop", {
        category       = "WATCHDOG",
        time_on_server = math.floor(tick() - serverStartTick),
    })
    pcall(Tools.endSession)
    -- ставим скрипт на следующий сервер если ещё не поставлен
    pcall(function()
        if queueonteleport then
            queueonteleport('loadstring(game:HttpGet("'
                .. SCRIPT_URL .. '?t=' .. tick() .. '"))()')
        end
    end)
    -- единый шлюз: если hop уже идёт — не дёргаем телепорт повторно
    Tools.safeTeleport("hardcap-watchdog", function()
        game:GetService("TeleportService"):Teleport(PLACE_ID, player)
    end)
end)

-- ============================================================
-- Fallback watchdog: если даже hard cap не сработал — через 60с ещё попытка
-- ============================================================
task.spawn(function()
    task.wait(MAX_SERVER_TIME_SEC + 60)
    Tools.logCritical("Fallback watchdog: ещё одна попытка телепорта", { category = "WATCHDOG" })
    pcall(Tools._flushLogs)
    -- последний резерв: если предыдущий телепорт завис в IsHopping, форсируем
    _G.IsHopping = false
    Tools.safeTeleport("fallback-watchdog", function()
        game:GetService("TeleportService"):Teleport(PLACE_ID, player)
    end, true)
end)

-- ============================================================
-- Глобальный xpcall
-- ============================================================
task.spawn(function()
    local ok, err = xpcall(runBot, function(e)
        return tostring(e) .. "\n" .. debug.traceback("", 2)
    end)
    if not ok then
        Tools.logCritical("runBot упал с исключением", {
            category = "EXCEPTION", error = tostring(err),
        })
        pcall(Tools._flushLogs)
        task.wait(3)
        pcall(Tools.fastServerHop)
    end
end)
