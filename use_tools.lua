local V = 'v1.12.0'
local PLACE_ID = 920587237 
local MIN_PLAYERS_PREFERRED = 5 
local MAX_PLAYERS_ALLOWED = 100
local SEARCH_TIMEOUT = 60
local TELEPORT_COOLDOWN = 15
local SCRIPT_URL = "https://raw.githubusercontent.com/MaxZarev/rblx/refs/heads/main/use_tools.lua"
local WATCHDOG_TIMEOUT = 360
local API_URL = "https://c8g8g0wc8gswogk8cs0ocgsw.146.103.101.22.sslip.io"

local Tools = loadstring(game:HttpGet("https://raw.githubusercontent.com/MaxZarev/rblx/main/tools.lua?t=" .. tick()))()
local Auth = loadstring(game:HttpGet("https://raw.githubusercontent.com/MaxZarev/rblx/main/auth.lua?t=" .. tick()))()

if _G.BotRunning then
    warn("Скрипт уже запущен!")
    return
end
_G.BotRunning = true

local Players = game:GetService("Players")
local player = Players.LocalPlayer

local function runBot()
    local botState = Tools.getBotState()
    if not botState.running then return end

    Tools.setup(API_URL, Tools.apiKey, MIN_PLAYERS_PREFERRED, MAX_PLAYERS_ALLOWED, SEARCH_TIMEOUT, TELEPORT_COOLDOWN, PLACE_ID, SCRIPT_URL, Auth)
    Tools.enabled = true

    task.spawn(function()
        task.wait(WATCHDOG_TIMEOUT)

        pcall(function() Tools.logWarning("Watchdog таймаут", {category = "WATCHDOG", timeout = WATCHDOG_TIMEOUT}) end)

        for i = 1, 3 do
            pcall(function() Tools.serverHop() end)
            task.wait(30)
        end

        pcall(function()
            game:GetService("TeleportService"):Teleport(PLACE_ID, player)
        end)
    end)

    Tools.logInfo("Скрипт запущен", {category = "BOT", version = V})
    Tools.connectChatListener()

    Tools.randomDelay(3, 7)

    if not botState.running then
        Tools.logInfo("Остановлен пользователем", {category = "BOT"})
        return
    end

    if Tools.waitForPlayButton(20) then
        Tools.randomDelay(3, 6)
        Tools.clickPlayButton()
    else
        Tools.logWarning("PlayButton не найден", {category = "BOT"})
    end

    if Tools.waitForAdoptionIslandButton(20) then
        Tools.randomDelay(3, 6)
        local success, message = Tools.clickAdoptionIslandButton()
        if not success then
            Tools.logWarning("Клик по кнопке Adoption Island не выполнен", {category = "BOT"})
        end
    end

    if not botState.running then
        Tools.logInfo("Остановлен пользователем", {category = "BOT"})
        return
    end

    Tools.randomDelay(5, 10)

    local casualMsg = Tools.getCasualMessage()
    Tools.sendChat(casualMsg)

    Tools.randomDelay(8, 15)

    if not botState.running then
        Tools.logInfo("Остановлен пользователем", {category = "BOT"})
        return
    end

    local adData = Tools.getAdMessage()

    if adData then
        Tools.sendChat(adData.message)
        Tools.checkAndDeactivateIfFiltered(adData.id, 2)
    else
        Tools.sendChat("RBLX . PW - sell you pets for real money")
        Tools.logWarning("Использован fallback для рекламного сообщения", {category = "AD"})
    end

    Tools.randomDelay(3, 5)

    if not botState.running then
        Tools.logInfo("Остановлен пользователем", {category = "BOT"})
        return
    end

    Tools.serverHop()
end

-- Запускаем autoReconnect сразу при загрузке скрипта, независимо от состояния бота
Tools.autoReconnect()


local savedApiKey = Tools.loadSavedApiKey()
local savedConfig = Tools.loadConfig()

if savedConfig then
    if savedConfig.minPlayersPreferred then
        MIN_PLAYERS_PREFERRED = savedConfig.minPlayersPreferred
        Tools.minPlayersPreferred = savedConfig.minPlayersPreferred
    end
end

if savedApiKey then
    local botState = Tools.getBotState()
    botState.running = true
    
    Tools.createSettingsGUI(runBot)
    
    task.spawn(function()
        runBot()
    end)
else
    Tools.createSettingsGUI(runBot)
end
