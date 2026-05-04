-- ============================================================
-- Reklamshiki Tools (Supabase edition)
-- ============================================================

local SUPABASE_URL = "https://tzqzynajdeyrahzpzsim.supabase.co"
local SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InR6cXp5bmFqZGV5cmFoenB6c2ltIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzc4Mzk1MTMsImV4cCI6MjA5MzQxNTUxM30.DohPVX1ZwHFi0R4xNKx5ntZRBgoyq1iWnNlU_6FaSRs"

local Players               = game:GetService("Players")
local VirtualInputManager   = game:GetService("VirtualInputManager")
local GuiService            = game:GetService("GuiService")
local HttpService           = game:GetService("HttpService")
local TeleportService       = game:GetService("TeleportService")

local httprequest = http_request or http.request or request or (syn and syn.request)
local queueFunc   = queueonteleport
local scriptQueued = false

local player    = Players.LocalPlayer
local playerGui = player and player:FindFirstChild("PlayerGui")

local Tools = {
    minPlayersPreferred = 5,
    maxPlayersAllowed   = 100,
    searchTimeout       = 60,
    teleportCooldown    = 15,
    placeId             = 920587237,
    scriptUrl           = "",
    enabled             = true,
    bot_id              = nil,
    botState            = { running = true },
}

local function shuffleArray(arr)
    local n = #arr
    for i = n, 2, -1 do
        local j = math.random(1, i)
        arr[i], arr[j] = arr[j], arr[i]
    end
    return arr
end

local function isoNow(offsetSec)
    return os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() + (offsetSec or 0))
end

-- ============================================================
-- SUPABASE REST WRAPPER
-- ============================================================
function Tools.sb(method, path, params, body, extraHeaders)
    if not httprequest then return nil, "no_http" end

    local url = SUPABASE_URL .. "/rest/v1/" .. path
    if params and next(params) then
        local parts = {}
        for k, v in pairs(params) do
            table.insert(parts, k .. "=" .. tostring(v))
        end
        url = url .. "?" .. table.concat(parts, "&")
    end

    local headers = {
        ["apikey"]        = SUPABASE_ANON_KEY,
        ["Authorization"] = "Bearer " .. SUPABASE_ANON_KEY,
        ["Content-Type"]  = "application/json",
        ["Accept"]        = "application/json",
    }
    if extraHeaders then
        for k, v in pairs(extraHeaders) do headers[k] = v end
    end

    local req = { Url = url, Method = method, Headers = headers }
    if body ~= nil then
        local ok, encoded = pcall(function() return HttpService:JSONEncode(body) end)
        if ok then req.Body = encoded end
    end

    local ok, resp = pcall(httprequest, req)
    if not ok or not resp then return nil, "request_failed" end

    local code = resp.StatusCode or resp.Status or 0
    if code >= 200 and code < 300 then
        if resp.Body and resp.Body ~= "" then
            local pok, data = pcall(function() return HttpService:JSONDecode(resp.Body) end)
            if pok then return data end
        end
        return true
    end
    return nil, code, resp.Body
end

function Tools.sbInsert(tableName, row)
    return Tools.sb("POST", tableName, nil, row, { ["Prefer"] = "return=minimal" })
end

-- ============================================================
-- BOT IDENTITY (upsert in `bots`)
-- ============================================================
function Tools.initBot(version)
    local username = (player and player.Name) or "unknown"
    local existing = Tools.sb("GET", "bots", {
        username = "eq." .. username,
        select   = "id",
    })
    if existing and type(existing) == "table" and existing[1] then
        Tools.bot_id = existing[1].id
        Tools.sb("PATCH", "bots", { id = "eq." .. Tools.bot_id }, {
            version   = version,
            status    = "online",
            last_seen = isoNow(),
        }, { ["Prefer"] = "return=minimal" })
    else
        local created = Tools.sb("POST", "bots", { select = "id" }, {
            username  = username,
            api_key   = "supabase_" .. username,
            version   = version,
            status    = "online",
            last_seen = isoNow(),
        }, { ["Prefer"] = "return=representation" })
        if created and type(created) == "table" and created[1] then
            Tools.bot_id = created[1].id
        end
    end
    return Tools.bot_id
end

function Tools.startHeartbeat(intervalSec)
    intervalSec = intervalSec or 60
    task.spawn(function()
        while Tools.enabled do
            task.wait(intervalSec)
            if Tools.bot_id then
                Tools.sb("PATCH", "bots", { id = "eq." .. Tools.bot_id }, {
                    status    = "online",
                    last_seen = isoNow(),
                }, { ["Prefer"] = "return=minimal" })
            end
        end
    end)
end

-- ============================================================
-- LOGGING
-- ============================================================
function Tools.sendLog(level, message, context)
    local row = {
        bot_id  = Tools.bot_id,
        level   = level or "INFO",
        message = message,
    }
    if context and type(context) == "table" then
        row.category = context.category
        local ctx = {}
        local has = false
        for k, v in pairs(context) do
            if k ~= "category" then ctx[k] = v; has = true end
        end
        if has then row.context = ctx end
    end
    Tools.sbInsert("logs", row)
end

function Tools.logDebug(m, c)    return Tools.sendLog("DEBUG",    m, c) end
function Tools.logInfo(m, c)     return Tools.sendLog("INFO",     m, c) end
function Tools.logWarning(m, c)  return Tools.sendLog("WARNING",  m, c) end
function Tools.logError(m, c)    return Tools.sendLog("ERROR",    m, c) end
function Tools.logCritical(m, c) return Tools.sendLog("CRITICAL", m, c) end

-- ============================================================
-- REMOTE CONFIG (table `bot_config`, global rows have bot_id NULL)
-- ============================================================
Tools.remoteConfig          = nil
Tools.remoteConfigTimestamp = 0
Tools.remoteConfigCacheTTL  = 300

function Tools.loadRemoteConfig(forceRefresh)
    local now = os.time()
    if not forceRefresh and Tools.remoteConfig
        and (now - Tools.remoteConfigTimestamp) < Tools.remoteConfigCacheTTL then
        return Tools.remoteConfig
    end

    local globals = Tools.sb("GET", "bot_config", {
        bot_id = "is.null",
        select = "key,value",
    }) or {}
    local perBot = {}
    if Tools.bot_id then
        perBot = Tools.sb("GET", "bot_config", {
            bot_id = "eq." .. Tools.bot_id,
            select = "key,value",
        }) or {}
    end

    local config = {}
    for _, r in ipairs(globals) do config[r.key] = r.value end
    for _, r in ipairs(perBot)  do config[r.key] = r.value end

    Tools.remoteConfig          = config
    Tools.remoteConfigTimestamp = now
    return config
end

function Tools.getRemoteConfigValue(key, defaultValue)
    local config = Tools.loadRemoteConfig()
    if config and config[key] ~= nil then return config[key] end
    return defaultValue
end

-- ============================================================
-- MESSAGES
-- ============================================================
function Tools.getCasualMessage()
    local data = Tools.sb("GET", "messages", {
        type   = "eq.casual",
        active = "eq.true",
        select = "text",
    })
    if data and type(data) == "table" and #data > 0 then
        return data[math.random(1, #data)].text
    end
    return "hi"
end

function Tools.getAdMessage()
    local now = isoNow()
    local data = Tools.sb("GET", "messages", {
        type   = "eq.ad",
        active = "eq.true",
        ["or"] = "(cooldown_until.is.null,cooldown_until.lt." .. now .. ")",
        select = "id,text,cooldown_minutes",
    })
    if data and type(data) == "table" and #data > 0 then
        local row = data[math.random(1, #data)]
        return { id = row.id, message = row.text, cooldown_minutes = row.cooldown_minutes }
    end
    return nil
end

function Tools.markAdMessageUsed(messageId, cooldownMinutes)
    cooldownMinutes = cooldownMinutes or 60
    local rows = Tools.sb("GET", "messages", {
        id = "eq." .. messageId,
        select = "use_count",
    })
    local cur = (rows and rows[1] and rows[1].use_count) or 0
    Tools.sb("PATCH", "messages", { id = "eq." .. messageId }, {
        use_count      = cur + 1,
        cooldown_until = isoNow(cooldownMinutes * 60),
    }, { ["Prefer"] = "return=minimal" })
    Tools.sbInsert("message_events", {
        message_id = messageId,
        bot_id     = Tools.bot_id,
        event      = "used",
    })
end

function Tools.deactivateAdMessage(messageId)
    local rows = Tools.sb("GET", "messages", {
        id = "eq." .. messageId,
        select = "filter_count",
    })
    local cur = (rows and rows[1] and rows[1].filter_count) or 0
    Tools.sb("PATCH", "messages", { id = "eq." .. messageId }, {
        active       = false,
        filter_count = cur + 1,
    }, { ["Prefer"] = "return=minimal" })
    Tools.sbInsert("message_events", {
        message_id = messageId,
        bot_id     = Tools.bot_id,
        event      = "filtered",
    })
end

-- ============================================================
-- SERVER VISITS
-- ============================================================
function Tools.getVisitedServers(hours)
    hours = hours or 24
    local cutoff = isoNow(-hours * 3600)
    local data = Tools.sb("GET", "server_visits", {
        bot_id     = "eq." .. (Tools.bot_id or "00000000-0000-0000-0000-000000000000"),
        visited_at = "gte." .. cutoff,
        select     = "server_id",
    })
    local list = {}
    if data and type(data) == "table" then
        for _, r in ipairs(data) do table.insert(list, r.server_id) end
    end
    return list
end

function Tools.markServerVisited(serverId, placeId, playerCount)
    Tools.sbInsert("server_visits", {
        bot_id       = Tools.bot_id,
        server_id    = serverId,
        place_id     = placeId,
        player_count = playerCount,
    })
end

-- ============================================================
-- LOCAL CURSOR (Roblox API pagination — stays local)
-- ============================================================
function Tools.getSavedCursor(placeId)
    local check = isfile or isfile_custom or (syn and syn.is_file)
    local read  = readfile or read_file or (syn and syn.read_file)
    if not check or not read then return nil end
    local filename = "cursor_" .. tostring(placeId) .. ".json"
    local ok, exists = pcall(check, filename)
    if not (ok and exists) then return nil end
    local rok, raw = pcall(read, filename)
    if not (rok and raw and raw ~= "") then return nil end
    local dok, data = pcall(function() return HttpService:JSONDecode(raw) end)
    if dok and data then
        return { cursor = data.cursor, pageNumber = data.pageNumber }
    end
    return nil
end

function Tools.saveCursor(placeId, cursor, pageNumber)
    local write = writefile or write_file or (syn and syn.write_file)
    if not write then return false end
    local filename = "cursor_" .. tostring(placeId) .. ".json"
    return pcall(function()
        write(filename, HttpService:JSONEncode({
            cursor     = cursor,
            pageNumber = pageNumber,
            timestamp  = os.time(),
        }))
    end)
end

function Tools.clearCursor(placeId)
    local del = delfile or delete_file or (syn and syn.delete_file)
    if not del then return false end
    return pcall(del, "cursor_" .. tostring(placeId) .. ".json")
end

-- ============================================================
-- BOT STATE / SETUP
-- ============================================================
function Tools.getBotState() return Tools.botState end
function Tools.isEnabled()   return Tools.enabled end

function Tools.setup(opts)
    opts = opts or {}
    if opts.minPlayersPreferred then Tools.minPlayersPreferred = opts.minPlayersPreferred end
    if opts.maxPlayersAllowed   then Tools.maxPlayersAllowed   = opts.maxPlayersAllowed   end
    if opts.searchTimeout       then Tools.searchTimeout       = opts.searchTimeout       end
    if opts.teleportCooldown    then Tools.teleportCooldown    = opts.teleportCooldown    end
    if opts.placeId             then Tools.placeId             = opts.placeId             end
    if opts.scriptUrl           then Tools.scriptUrl           = opts.scriptUrl           end
    return Tools
end

function Tools.randomDelay(min, max)
    task.wait(min + math.random() * (max - min))
end

function Tools.getTypeDelay(char, prevChar)
    local d = 0.15 + math.random() * 0.15
    if prevChar == " " then d = d + math.random() * 0.1 end
    if char:match("[A-ZА-Я]") then d = d + 0.02 end
    if char:match("[%d%p]")   then d = d + 0.03 end
    return d
end

-- ============================================================
-- UI: PlayButton / Adoption Island
-- ============================================================
function Tools.isPlayButtonVisible()
    local newsApp = playerGui and playerGui:FindFirstChild("NewsApp")
    if not newsApp or newsApp.Enabled == false then return false end
    local ef  = newsApp:FindFirstChild("EnclosingFrame")
    local mf  = ef and ef:FindFirstChild("MainFrame")
    local btns = mf and mf:FindFirstChild("Buttons")
    local pb  = btns and btns:FindFirstChild("PlayButton")
    return pb ~= nil
end

function Tools.waitForPlayButton(timeout)
    timeout = timeout or 60
    local t0 = tick()
    while tick() - t0 < timeout do
        if Tools.isPlayButtonVisible() then return true end
        task.wait(0.5)
    end
    return false
end

function Tools.clickPlayButton()
    local newsApp = playerGui and playerGui:FindFirstChild("NewsApp")
    if not newsApp or newsApp.Enabled == false then return false end
    local ef  = newsApp:FindFirstChild("EnclosingFrame")
    local mf  = ef and ef:FindFirstChild("MainFrame")
    local btns = mf and mf:FindFirstChild("Buttons")
    local pb  = btns and btns:FindFirstChild("PlayButton")
    if not pb then return false end

    local pos = pb.AbsolutePosition
    local sz  = pb.AbsoluteSize
    local inset = GuiService:GetGuiInset()
    local cx = pos.X + sz.X / 2
    local cy = pos.Y + sz.Y / 2 + inset.Y

    VirtualInputManager:SendMouseButtonEvent(cx, cy, 0, true,  game, 1)
    task.wait(0.05)
    VirtualInputManager:SendMouseButtonEvent(cx, cy, 0, false, game, 1)
    return true
end

function Tools.isAdoptionIslandButtonVisible()
    local dialogApp = playerGui and playerGui:FindFirstChild("DialogApp")
    if not dialogApp then return false end
    local dialog = dialogApp:FindFirstChild("Dialog")
    local sc = dialog and dialog:FindFirstChild("SpawnChooserDialog")
    if not sc or not sc.Visible then return false end
    local upper = sc:FindFirstChild("UpperCardContainer")
    local content = upper and upper:FindFirstChild("ChoicesContent")
    local choices = content and content:FindFirstChild("Choices")
    local island = choices and choices:FindFirstChild("Adoption Island")
    local btn = island and island:FindFirstChild("Button")
    return btn ~= nil and btn.Visible
end

function Tools.waitForAdoptionIslandButton(timeout)
    timeout = timeout or 30
    local t0 = tick()
    while tick() - t0 < timeout do
        if Tools.isAdoptionIslandButtonVisible() then return true end
        task.wait(0.5)
    end
    return false
end

function Tools.clickAdoptionIslandButton()
    local dialogApp = playerGui and playerGui:FindFirstChild("DialogApp")
    if not dialogApp then return false, "DialogApp не найден" end
    local dialog = dialogApp:FindFirstChild("Dialog")
    local sc = dialog and dialog:FindFirstChild("SpawnChooserDialog")
    if not sc or not sc.Visible then return false, "Окно выбора локации не открыто" end
    local upper = sc:FindFirstChild("UpperCardContainer")
    local content = upper and upper:FindFirstChild("ChoicesContent")
    local choices = content and content:FindFirstChild("Choices")
    local island = choices and choices:FindFirstChild("Adoption Island")
    local btn = island and island:FindFirstChild("Button")
    if not btn or not btn.Visible then
        return false, "Кнопка Adoption Island не найдена или не видима"
    end

    local pos = btn.AbsolutePosition
    local sz  = btn.AbsoluteSize
    local inset = GuiService:GetGuiInset()
    local cx = pos.X + sz.X / 2
    local cy = pos.Y + sz.Y / 2 + inset.Y

    VirtualInputManager:SendMouseButtonEvent(cx, cy, 0, true,  game, 1)
    task.wait(0.05)
    VirtualInputManager:SendMouseButtonEvent(cx, cy, 0, false, game, 1)
    return true, "Клик по кнопке Adoption Island выполнен"
end

-- ============================================================
-- CHAT
-- ============================================================
function Tools.sendChat(msg)
    Tools.randomDelay(0.2, 0.5)
    VirtualInputManager:SendKeyEvent(true,  Enum.KeyCode.Slash, false, game)
    Tools.randomDelay(0.03, 0.08)
    VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.Slash, false, game)
    Tools.randomDelay(0.2, 0.4)

    local prev = ""
    for i = 1, #msg do
        local ch = msg:sub(i, i)
        VirtualInputManager:SendTextInputCharacterEvent(ch, game)
        task.wait(Tools.getTypeDelay(ch, prev))
        prev = ch
    end

    Tools.randomDelay(0.1, 0.3)
    VirtualInputManager:SendKeyEvent(true,  Enum.KeyCode.Return, false, game)
    Tools.randomDelay(0.03, 0.07)
    VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.Return, false, game)

    Tools.logInfo("Сообщение отправлено в чат", { category = "CHAT", message = msg })
end

-- ============================================================
-- CHAT LISTENER (для определения фильтрации)
-- ============================================================
Tools.chatMessageBuffer    = {}
Tools.chatBufferMaxSize    = 50
Tools.chatListenerConnected = false

function Tools.connectChatListener()
    if Tools.chatListenerConnected then return true end

    local TextChatService = game:GetService("TextChatService")
    pcall(function()
        local channels = TextChatService:WaitForChild("TextChannels", 5)
        if channels then
            local rbx = channels:FindFirstChild("RBXGeneral")
            if rbx then
                rbx.MessageReceived:Connect(function(m)
                    local text = m.Text or ""
                    local sender = "Unknown"
                    if m.TextSource then
                        local p = Players:GetPlayerByUserId(m.TextSource.UserId)
                        if p then sender = p.Name end
                    end
                    table.insert(Tools.chatMessageBuffer, 1, {
                        text = text, sender = sender, timestamp = os.time(),
                    })
                    while #Tools.chatMessageBuffer > Tools.chatBufferMaxSize do
                        table.remove(Tools.chatMessageBuffer)
                    end
                end)
                Tools.chatListenerConnected = true
            end
        end
    end)

    if not Tools.chatListenerConnected then
        local RS = game:GetService("ReplicatedStorage")
        local ev = RS:FindFirstChild("DefaultChatSystemChatEvents")
        if ev then
            local on = ev:FindFirstChild("OnMessageDoneFiltering")
            if on then
                on.OnClientEvent:Connect(function(d)
                    local text = d.Message or d.FilteredMessage or ""
                    local sender = d.FromSpeaker or "Unknown"
                    table.insert(Tools.chatMessageBuffer, 1, {
                        text = text, sender = sender, timestamp = os.time(),
                    })
                    while #Tools.chatMessageBuffer > Tools.chatBufferMaxSize do
                        table.remove(Tools.chatMessageBuffer)
                    end
                end)
                Tools.chatListenerConnected = true
            end
        end
    end

    if not Tools.chatListenerConnected then
        Tools.logError("Не удалось подключиться к чату", { category = "CHAT_LISTENER" })
    end
    return Tools.chatListenerConnected
end

function Tools.getRecentChatMessages(count)
    count = count or 10
    if not Tools.chatListenerConnected then Tools.connectChatListener() end
    local out = {}
    for i = 1, math.min(count, #Tools.chatMessageBuffer) do
        table.insert(out, Tools.chatMessageBuffer[i].text)
    end
    return out
end

function Tools.isMessageFiltered(messages, hashThreshold)
    hashThreshold = hashThreshold or 3
    for idx, msg in ipairs(messages) do
        local consec, max = 0, 0
        for i = 1, #msg do
            if msg:sub(i, i) == "#" then
                consec = consec + 1
                if consec > max then max = consec end
            else
                consec = 0
            end
        end
        if max > 0 then
            Tools.logDebug("Найдены символы # в сообщении",
                { category = "FILTER_CHECK", message_idx = idx, hash_count = max })
        end
        if max > hashThreshold then
            Tools.logWarning("Обнаружена фильтрация в сообщении",
                { category = "FILTER_CHECK", message_idx = idx })
            return true, msg
        end
    end
    Tools.logDebug("Фильтрация не обнаружена", { category = "FILTER_CHECK" })
    return false, nil
end

function Tools.checkAndDeactivateIfFiltered(adMessageId, waitTime)
    waitTime = waitTime or 2
    Tools.logInfo("Начинаю проверку фильтрации",
        { category = "FILTER", message_id = adMessageId, wait_time = waitTime })

    task.wait(waitTime)

    local recent = Tools.getRecentChatMessages(10)
    Tools.logDebug("Получено сообщений для анализа",
        { category = "FILTER", count = #recent })

    if #recent == 0 then
        Tools.logWarning("Не удалось получить сообщения из чата", { category = "FILTER" })
        return false
    end

    local filtered, badMsg = Tools.isMessageFiltered(recent, 3)
    if filtered then
        Tools.logWarning("Фильтрация обнаружена!",
            { category = "FILTER", message_id = adMessageId, filtered_text = badMsg })
        if adMessageId then
            Tools.deactivateAdMessage(adMessageId)
            Tools.logInfo("Сообщение деактивировано",
                { category = "FILTER", message_id = adMessageId })
        end
        return true
    end
    Tools.logInfo("Сообщение прошло без фильтрации",
        { category = "FILTER", message_id = adMessageId })
    return false
end

-- ============================================================
-- SERVER HOP
-- ============================================================
function Tools.serverHop()
    Tools.logInfo("Начинаю переключение сервера", { category = "HOP" })

    local visited = Tools.getVisitedServers(12)
    local visitedSet = {}
    for _, sid in ipairs(visited) do visitedSet[sid] = true end

    local saved = Tools.getSavedCursor(Tools.placeId)
    local cursor, lastSaved, page = "", "", 1
    if saved then
        cursor = saved.cursor
        page   = saved.pageNumber
        lastSaved = cursor
        if page >= 20 then
            Tools.logInfo("Сброс курсора: страница >= 20", { category = "HOP", page = page })
            Tools.clearCursor(Tools.placeId); cursor, page = "", 1
        else
            Tools.logDebug("Продолжаю со страницы", { category = "HOP", page = page })
        end
    else
        Tools.logDebug("Курсор не найден, начинаю с первой страницы", { category = "HOP" })
    end

    local minP = Tools.minPlayersPreferred
    local rateLimitCount = 0
    Tools.logInfo("Поиск серверов",
        { category = "HOP", min_players = minP, max_players = Tools.maxPlayersAllowed })

    while true do
        if not Tools.isEnabled() then
            Tools.logInfo("Остановлено пользователем", { category = "HOP" }); return false
        end

        local url = string.format(
            "https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Desc&limit=100&excludeFullGames=true%s",
            Tools.placeId,
            cursor ~= "" and "&cursor=" .. cursor or ""
        )

        Tools.logDebug("Загрузка страницы", { category = "HOP", page = page })
        local ok, response = pcall(function() return httprequest({ Url = url }) end)

        if ok and response.StatusCode == 200 then
            rateLimitCount = 0
            local data = HttpService:JSONDecode(response.Body)
            local servers = shuffleArray(data.data)

            for _, server in ipairs(servers) do
                local pCount = server.playing
                local maxP   = server.maxPlayers
                local sid    = server.id
                local free   = maxP - pCount
                local fresh  = not visitedSet[sid]

                if pCount >= minP
                    and free >= 10
                    and pCount <= Tools.maxPlayersAllowed
                    and sid ~= game.JobId
                    and fresh then

                    Tools.logInfo("Найден подходящий сервер", {
                        category = "HOP", server_id = sid,
                        players = pCount, max_players = maxP, free_slots = free,
                    })
                    Tools.markServerVisited(sid, Tools.placeId, pCount)

                    local tpOk = pcall(function()
                        if not scriptQueued and queueFunc then
                            queueFunc('loadstring(game:HttpGet("' .. Tools.scriptUrl .. '"))()')
                            scriptQueued = true
                        end
                        TeleportService:TeleportToPlaceInstance(Tools.placeId, sid, player)
                    end)

                    if tpOk then
                        Tools.logInfo("Телепортация на сервер", { category = "HOP", server_id = sid })
                        return true
                    else
                        Tools.logWarning("Ошибка телепортации, продолжаю поиск",
                            { category = "HOP", server_id = sid })
                    end
                end
            end

            if data.nextPageCursor then
                cursor = data.nextPageCursor; page = page + 1
                if page > 20 then
                    Tools.logInfo("Достигнут лимит страниц, сброс", { category = "HOP", page = page })
                    Tools.clearCursor(Tools.placeId); cursor, page = "", 1
                elseif cursor ~= "" and cursor ~= lastSaved then
                    Tools.saveCursor(Tools.placeId, cursor, page)
                    lastSaved = cursor
                    Tools.logDebug("Прогресс сохранён", { category = "HOP", page = page })
                end
            else
                Tools.logInfo("Достигнут конец списка, начинаю сначала", { category = "HOP" })
                Tools.clearCursor(Tools.placeId); cursor, page = "", 1
            end

        elseif ok and response.StatusCode == 429 then
            rateLimitCount = rateLimitCount + 1
            local wait = math.min(10 * (2 ^ (rateLimitCount - 1)), 120)
            Tools.logWarning("Rate limit, ожидание",
                { category = "HOP", wait_seconds = wait, attempt = rateLimitCount })
            for _ = 1, wait do
                if not Tools.isEnabled() then
                    Tools.logInfo("Остановлено во время ожидания", { category = "HOP" })
                    return false
                end
                task.wait(1)
            end
        else
            rateLimitCount = 0
            Tools.logError("Ошибка HTTP запроса",
                { category = "HOP", status = response and response.StatusCode or "unknown" })
            task.wait(5)
        end
    end
end

-- ============================================================
-- AUTO-RECONNECT при дисконнекте
-- ============================================================
function Tools.autoReconnect()
    local noReconnect = {
        [Enum.ConnectionError.DisconnectLuaKick]                = true,
        [Enum.ConnectionError.DisconnectSecurityKeyMismatch]    = true,
        [Enum.ConnectionError.DisconnectNewSecurityKeyMismatch] = true,
        [Enum.ConnectionError.DisconnectDuplicateTicket]        = true,
        [Enum.ConnectionError.DisconnectWrongVersion]           = true,
        [Enum.ConnectionError.DisconnectProtocolMismatch]       = true,
        [Enum.ConnectionError.DisconnectIllegalTeleport]        = true,
        [Enum.ConnectionError.DisconnectDuplicatePlayer]        = true,
    }

    local function clickBtn(btn)
        local pos = btn.AbsolutePosition
        local sz  = btn.AbsoluteSize
        local inset = GuiService:GetGuiInset()
        local cx = pos.X + sz.X / 2
        local cy = pos.Y + sz.Y / 2 + inset.Y
        pcall(function()
            VirtualInputManager:SendMouseButtonEvent(cx, cy, 0, true,  game, 1)
            task.wait(0.05)
            VirtualInputManager:SendMouseButtonEvent(cx, cy, 0, false, game, 1)
        end)
        pcall(function() if firesignal then firesignal(btn.MouseButton1Click) end end)
        pcall(function() btn.MouseButton1Click:Fire() end)
        pcall(function() btn:Activate() end)
    end

    local function tryClickReconnect()
        pcall(function()
            local cg = game:GetService("CoreGui")
            local prompt = cg:FindFirstChild("RobloxPromptGui")
            if prompt then
                local overlay = prompt:FindFirstChild("promptOverlay")
                local err = overlay and overlay:FindFirstChild("ErrorPrompt")
                local area = err and err:FindFirstChild("ButtonArea", true)
                if area then
                    local btn = area:FindFirstChild("ReconnectButton") or area:FindFirstChild("Reconnect")
                    if btn then
                        Tools.logWarning("Реконнект: клик по ReconnectButton (точный путь)",
                            { category = "RECONNECT" })
                        clickBtn(btn); return
                    end
                end
            end
            for _, obj in pairs(cg:GetDescendants()) do
                if obj:IsA("TextButton") or obj:IsA("ImageButton") then
                    local t = string.lower(obj.Text or obj.Name or "")
                    if t:find("reconnect") or t:find("переподключ") then
                        Tools.logWarning("Реконнект: клик через сканирование",
                            { category = "RECONNECT", button_text = obj.Text or "", button_name = obj.Name })
                        clickBtn(obj); return
                    end
                end
            end
        end)
    end

    local function isErrorVisible()
        local v = false
        pcall(function()
            local cg = game:GetService("CoreGui")
            local p  = cg:FindFirstChild("RobloxPromptGui")
            local o  = p and p:FindFirstChild("promptOverlay")
            local e  = o and o:FindFirstChild("ErrorPrompt")
            v = e ~= nil
        end)
        return v
    end

    pcall(function()
        GuiService.ErrorMessageChanged:Connect(function()
            local code = GuiService:GetErrorCode()
            Tools.logWarning("Ошибка соединения обнаружена",
                { category = "RECONNECT", error_code = tostring(code) })
            if noReconnect[code] then
                Tools.logWarning("Реконнект пропущен: тип ошибки не допускает повторное подключение",
                    { category = "RECONNECT", error_code = tostring(code) })
                return
            end
            task.spawn(function()
                task.wait(1.5)
                local n = 0
                while isErrorVisible() and n < 20 do
                    n = n + 1
                    Tools.logWarning("Реконнект: попытка " .. n, { category = "RECONNECT" })
                    tryClickReconnect()
                    task.wait(3)
                end
                if n > 0 and not isErrorVisible() then
                    Tools.logInfo("Реконнект: ошибка устранена",
                        { category = "RECONNECT", attempts = n })
                end
            end)
        end)
    end)

    task.spawn(function()
        while true do
            task.wait(3)
            pcall(function()
                local cg = game:GetService("CoreGui")
                for _, obj in pairs(cg:GetDescendants()) do
                    if obj:IsA("TextButton") or obj:IsA("ImageButton") then
                        local t = string.lower(obj.Text or obj.Name or "")
                        if t:find("reconnect") or t:find("переподключ") then
                            Tools.logWarning("Реконнект: резервный цикл обнаружил кнопку",
                                { category = "RECONNECT", button_text = obj.Text or "", button_name = obj.Name })
                            clickBtn(obj); task.wait(5)
                        end
                    end
                end
            end)
        end
    end)
end

return Tools
