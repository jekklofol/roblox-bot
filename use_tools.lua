local V                     = "v3.19.0-wider-reach"
local PLACE_ID              = 920587237
local MIN_PLAYERS_PREFERRED = 5
local MAX_PLAYERS_ALLOWED   = 100
local SEARCH_TIMEOUT        = 60
local TELEPORT_COOLDOWN     = 15
local MAX_SERVER_TIME_SEC   = 360   -- жёсткий cap на время на одном сервере
local MIN_PLAYERS_FOR_AD    = 3     -- если меньше — реклама бесполезна, сразу hop
local TARGET_DWELL_MIN      = 90    -- сидим меньше → чаще меняем сервер → шире охват (новые
local TARGET_DWELL_MAX      = 150   -- аудитории вместо повтора одним людям). ~2-3 рекламы/заход.
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
Tools.startAntiAfk()

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

    -- Adoption Island есть НЕ на каждом сервере и появляется сразу — 2с хватает.
    -- Раньше ждали 6с впустую почти на каждом заходе (диалога обычно нет).
    if Tools.waitForAdoptionIslandButton(2) then
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
-- Watchdog-ЦИКЛ: после MAX_SERVER_TIME_SEC безусловно уводим с сервера и,
-- если уход не удался (полный сервер / зависший IsHopping), ПОВТОРЯЕМ каждые ~45с,
-- пока бот реально не сменит сервер (успешный TP уничтожит этот VM и оборвёт цикл).
-- Раньше было 2 разовые попытки (360с и 420с): если обе фейлились — бот застревал
-- навсегда (→ AFK-кик через 20 мин → зомби). Цикл это закрывает.
-- ============================================================
task.spawn(function()
    task.wait(MAX_SERVER_TIME_SEC)
    -- ставим скрипт на следующий сервер (один раз)
    pcall(function()
        if queueonteleport then
            queueonteleport('loadstring(game:HttpGet("'
                .. SCRIPT_URL .. '?t=' .. tick() .. '"))()')
        end
    end)
    local tries = 0
    while true do
        if not Tools.isEnabled() then return end   -- бот остановлен командой — не дёргаем
        tries = tries + 1
        Tools.logWarning("Watchdog: форс-увод с сервера (попытка " .. tries .. ")", {
            category       = "WATCHDOG",
            time_on_server = math.floor(tick() - serverStartTick),
        })
        pcall(Tools.endSession)
        pcall(Tools._flushLogs)
        _G.IsHopping = false   -- сбрасываем возможный зависший guard
        -- сначала на КОНКРЕТНЫЙ свободный сервер (без коллизий), иначе слепо
        pcall(function()
            if not Tools.teleportToConcreteServer("watchdog-loop") then
                Tools.safeTeleport("watchdog-loop-blind", function()
                    game:GetService("TeleportService"):Teleport(PLACE_ID, player)
                end, true)
            end
        end)
        task.wait(60)   -- успешный TP убьёт VM раньше; раз мы ещё тут — TP не прошёл, повторяем
        -- (60с > tpMinGap: даём зависшему телепорту разрешиться, не спамим поверх)
    end
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
