local V                     = "v2.0.0-supabase"
local PLACE_ID              = 920587237
local MIN_PLAYERS_PREFERRED = 5
local MAX_PLAYERS_ALLOWED   = 100
local SEARCH_TIMEOUT        = 60
local TELEPORT_COOLDOWN     = 15
local SCRIPT_URL            = "https://raw.githubusercontent.com/jekklofol/roblox-bot/refs/heads/main/use_tools.lua"
local WATCHDOG_TIMEOUT      = 360

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

Tools.initBot(V)
Tools.startHeartbeat(60)

local minOverride = tonumber(Tools.getRemoteConfigValue("min_players_preferred"))
if minOverride then Tools.minPlayersPreferred = minOverride end

Tools.autoReconnect()

local function runBot()
    if not Tools.getBotState().running then return end
    Tools.enabled = true

    task.spawn(function()
        task.wait(WATCHDOG_TIMEOUT)
        pcall(function()
            Tools.logWarning("Watchdog таймаут",
                { category = "WATCHDOG", timeout = WATCHDOG_TIMEOUT })
        end)
        for i = 1, 3 do
            pcall(function() Tools.serverHop() end)
            task.wait(30)
        end
        pcall(function()
            game:GetService("TeleportService"):Teleport(PLACE_ID, player)
        end)
    end)

    Tools.logInfo("Скрипт запущен", { category = "BOT", version = V })
    Tools.connectChatListener()
    Tools.randomDelay(3, 7)

    if Tools.waitForPlayButton(20) then
        Tools.randomDelay(3, 6)
        Tools.clickPlayButton()
    else
        Tools.logWarning("PlayButton не найден", { category = "BOT" })
    end

    if Tools.waitForAdoptionIslandButton(20) then
        Tools.randomDelay(3, 6)
        local ok = Tools.clickAdoptionIslandButton()
        if not ok then
            Tools.logWarning("Клик по кнопке Adoption Island не выполнен", { category = "BOT" })
        end
    end

    Tools.randomDelay(5, 10)

    local casual = Tools.getCasualMessage()
    Tools.sendChat(casual)
    Tools.randomDelay(8, 15)

    local ad = Tools.getAdMessage()
    if ad then
        Tools.sendChat(ad.message)
        local filtered = Tools.checkAndDeactivateIfFiltered(ad.id, 2)
        if not filtered then
            Tools.markAdMessageUsed(ad.id, ad.cooldown_minutes or 60)
        end
    else
        Tools.sendChat("RBLX . PW - sell you pets for real money")
        Tools.logWarning("Использован fallback для рекламного сообщения", { category = "AD" })
    end

    Tools.randomDelay(3, 5)
    Tools.serverHop()
end

task.spawn(runBot)
