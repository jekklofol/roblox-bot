-- ============================================================
-- Reklamshiki Tools (Supabase edition, v3)
--   * async batch-логирование
--   * sessions lifecycle + atomic RPC counters
--   * ускоренный чат
--   * bot_commands polling (управление из админки)
--   * расширенная телеметрия
-- ============================================================

local SUPABASE_URL      = "https://tzqzynajdeyrahzpzsim.supabase.co"
local SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InR6cXp5bmFqZGV5cmFoenB6c2ltIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzc4Mzk1MTMsImV4cCI6MjA5MzQxNTUxM30.DohPVX1ZwHFi0R4xNKx5ntZRBgoyq1iWnNlU_6FaSRs"

local Players             = game:GetService("Players")
local VirtualInputManager = game:GetService("VirtualInputManager")
local GuiService          = game:GetService("GuiService")
local HttpService         = game:GetService("HttpService")
local TeleportService     = game:GetService("TeleportService")
local Stats               = game:GetService("Stats")
local RunService          = game:GetService("RunService")

local httprequest = http_request or http.request or request or (syn and syn.request)
local queueFunc   = queueonteleport
local scriptQueued = false

local player    = Players.LocalPlayer
local playerGui = player and player:FindFirstChild("PlayerGui")

local Tools = {
    -- gameplay defaults
    minPlayersPreferred = 5,
    maxPlayersAllowed   = 100,
    searchTimeout       = 60,
    teleportCooldown    = 15,
    placeId             = 920587237,
    scriptUrl           = "",
    enabled             = true,

    -- identity
    bot_id      = nil,
    session_id  = nil,
    version     = nil,
    executor    = nil,

    -- runtime
    botState            = { running = true },
    chatSpeedMul        = 1.0,
    logFlushInterval    = 2,
    logBatchMax         = 50,
    commandPollInterval = 5,

    -- internal
    _logQueue           = {},
    _logQueueMax        = 500,
    _logFlushRunning    = false,
    _commandLoopRunning = false,
    _heartbeatRunning   = false,

    -- cached message pools (preloaded once per session)
    _adsCache           = nil,
    _casualCache        = nil,
    _msgCacheTimestamp  = 0,
    _msgCacheTTL        = 180,
}

-- ============================================================
-- UTILS
-- ============================================================
local function isoNow(offsetSec)
    return os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() + (offsetSec or 0))
end

local function durationMs(t0)
    return math.floor((tick() - t0) * 1000)
end

local function shuffleArray(arr)
    local n = #arr
    for i = n, 2, -1 do
        local j = math.random(1, i)
        arr[i], arr[j] = arr[j], arr[i]
    end
    return arr
end

local function detectExecutor()
    local ok, name = pcall(identifyexecutor)
    if ok and name then return name end
    if syn         then return "Synapse"     end
    if KRNL_LOADED then return "Krnl"        end
    if fluxus      then return "Fluxus"      end
    if Krnl        then return "Krnl"        end
    return "unknown"
end

local function safePcall(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then return nil, err end
    return ok, err
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

function Tools.sbRpc(fnName, args)
    return Tools.sb("POST", "rpc/" .. fnName, nil, args or {},
        { ["Prefer"] = "return=minimal" })
end

-- ============================================================
-- ASYNC BATCH LOGGING
-- ============================================================
local function buildLogRow(level, message, context)
    local row = {
        bot_id     = Tools.bot_id,
        session_id = Tools.session_id,
        level      = level or "INFO",
        message    = tostring(message or ""),
    }
    if context and type(context) == "table" then
        row.category = context.category
        local ctx, has = {}, false
        for k, v in pairs(context) do
            if k ~= "category" then ctx[k] = v; has = true end
        end
        if has then row.context = ctx end
    end
    return row
end

function Tools._enqueueLog(row)
    if #Tools._logQueue >= Tools._logQueueMax then
        -- очередь забита — дропаем самый старый, сохраняя свежие события
        table.remove(Tools._logQueue, 1)
    end
    table.insert(Tools._logQueue, row)
end

function Tools._flushLogs()
    if #Tools._logQueue == 0 then return end
    local batch = {}
    local take = math.min(#Tools._logQueue, Tools.logBatchMax)
    for _ = 1, take do
        table.insert(batch, table.remove(Tools._logQueue, 1))
    end
    -- bulk insert через PostgREST (array body)
    pcall(function()
        Tools.sb("POST", "logs", nil, batch, { ["Prefer"] = "return=minimal" })
    end)
end

function Tools._startLogFlushLoop()
    if Tools._logFlushRunning then return end
    Tools._logFlushRunning = true
    task.spawn(function()
        while Tools._logFlushRunning do
            task.wait(Tools.logFlushInterval)
            pcall(Tools._flushLogs)
        end
    end)
end

function Tools.sendLog(level, message, context)
    -- enqueue, не блокируем вызывающий поток
    Tools._enqueueLog(buildLogRow(level, message, context))
end

function Tools.logDebug(m, c)    return Tools.sendLog("DEBUG",    m, c) end
function Tools.logInfo(m, c)     return Tools.sendLog("INFO",     m, c) end
function Tools.logWarning(m, c)  return Tools.sendLog("WARNING",  m, c) end
function Tools.logError(m, c)    return Tools.sendLog("ERROR",    m, c) end
function Tools.logCritical(m, c) return Tools.sendLog("CRITICAL", m, c) end

-- защищённый вызов с автоматическим логированием ошибки
function Tools.guard(category, fn, ...)
    local args = { ... }
    local t0 = tick()
    local ok, err = xpcall(function() return fn(table.unpack(args)) end, function(e)
        return tostring(e) .. "\n" .. debug.traceback()
    end)
    if not ok then
        Tools.logError("Исключение в " .. (category or "unknown"), {
            category    = "EXCEPTION",
            origin      = category,
            error       = tostring(err),
            duration_ms = durationMs(t0),
        })
    end
    return ok, err
end

-- ============================================================
-- BOT IDENTITY
-- ============================================================
function Tools.initBot(version, extra)
    local username  = (player and player.Name)   or "unknown"
    local userId    = (player and player.UserId) or 0
    local executor  = detectExecutor()
    Tools.version   = version
    Tools.executor  = executor

    Tools._startLogFlushLoop()

    local meta = {
        version   = version,
        status    = "online",
        last_seen = isoNow(),
        place_id  = game.PlaceId,
        job_id    = game.JobId,
        user_id   = userId,
        executor  = executor,
    }
    if extra then
        for k, v in pairs(extra) do meta[k] = v end
    end

    local existing = Tools.sb("GET", "bots", {
        username = "eq." .. username,
        select   = "id",
    })

    if existing and type(existing) == "table" and existing[1] then
        Tools.bot_id = existing[1].id
        Tools.sb("PATCH", "bots", { id = "eq." .. Tools.bot_id }, meta,
            { ["Prefer"] = "return=minimal" })
    else
        meta.username = username
        meta.api_key  = "supabase_" .. username .. "_" .. tostring(math.random(100000, 999999))
        local created = Tools.sb("POST", "bots", { select = "id" }, meta,
            { ["Prefer"] = "return=representation" })
        if created and type(created) == "table" and created[1] then
            Tools.bot_id = created[1].id
        end
    end

    Tools.logInfo("Бот инициализирован", {
        category   = "BOT",
        bot_id     = Tools.bot_id,
        username   = username,
        version    = version,
        place_id   = game.PlaceId,
        job_id     = game.JobId,
        user_id    = userId,
        executor   = executor,
    })
    return Tools.bot_id
end

function Tools.startHeartbeat(intervalSec)
    intervalSec = intervalSec or 60
    if Tools._heartbeatRunning then return end
    Tools._heartbeatRunning = true
    task.spawn(function()
        while Tools.enabled and Tools._heartbeatRunning do
            task.wait(intervalSec)
            if Tools.bot_id then
                local t0 = tick()
                local ok = Tools.sb("PATCH", "bots", { id = "eq." .. Tools.bot_id }, {
                    status    = "online",
                    last_seen = isoNow(),
                }, { ["Prefer"] = "return=minimal" })
                Tools.logDebug("Heartbeat", {
                    category    = "BOT",
                    ok          = ok and true or false,
                    duration_ms = durationMs(t0),
                })
                if Tools.session_id then
                    pcall(function()
                        Tools.sbRpc("rpc_session_bump",
                            { p_session_id = Tools.session_id, p_field = "ping" })
                    end)
                end
            end
        end
    end)
end

-- ============================================================
-- SESSIONS
-- ============================================================
function Tools.startSession()
    if not Tools.bot_id then return nil end
    local created = Tools.sb("POST", "sessions", { select = "id" }, {
        bot_id     = Tools.bot_id,
        place_id   = game.PlaceId,
        job_id     = game.JobId,
        server_id  = game.JobId,
        version    = Tools.version,
    }, { ["Prefer"] = "return=representation" })
    if created and type(created) == "table" and created[1] then
        Tools.session_id = created[1].id
        Tools.logInfo("Сессия начата", {
            category   = "SESSION",
            session_id = Tools.session_id,
        })
    else
        Tools.logWarning("Не удалось создать сессию", { category = "SESSION" })
    end
    return Tools.session_id
end

function Tools.bumpSession(field)
    if not Tools.session_id then return end
    pcall(function()
        Tools.sbRpc("rpc_session_bump",
            { p_session_id = Tools.session_id, p_field = field })
    end)
end

function Tools.endSession()
    if not Tools.session_id then return end
    pcall(function()
        Tools.sb("PATCH", "sessions", { id = "eq." .. Tools.session_id }, {
            ended_at    = isoNow(),
            last_active = isoNow(),
        }, { ["Prefer"] = "return=minimal" })
    end)
end

-- ============================================================
-- REMOTE CONFIG
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

    Tools.logDebug("Удалённый конфиг загружен", {
        category = "CONFIG",
        keys     = (function()
            local k = {}
            for key in pairs(config) do table.insert(k, key) end
            return k
        end)(),
    })
    return config
end

function Tools.getRemoteConfigValue(key, defaultValue)
    local config = Tools.loadRemoteConfig()
    if config and config[key] ~= nil then return config[key] end
    return defaultValue
end

-- ============================================================
-- MESSAGES (с кэшированием)
-- ============================================================
function Tools.preloadMessages(force)
    local now = os.time()
    if not force and Tools._adsCache and Tools._casualCache
        and (now - Tools._msgCacheTimestamp) < Tools._msgCacheTTL then
        return
    end
    local t0 = tick()
    local data = Tools.sb("GET", "messages", {
        active = "eq.true",
        select = "id,text,type,cooldown_minutes,cooldown_until",
    }) or {}

    local ads, casual = {}, {}
    local nowIso = isoNow()
    for _, m in ipairs(data) do
        if m.type == "ad" then
            local cdOk = not m.cooldown_until or m.cooldown_until < nowIso
            if cdOk then table.insert(ads, m) end
        elseif m.type == "casual" then
            table.insert(casual, m)
        end
    end
    Tools._adsCache          = ads
    Tools._casualCache       = casual
    Tools._msgCacheTimestamp = now

    Tools.logDebug("Сообщения предзагружены", {
        category    = "MSG",
        ads         = #ads,
        casual      = #casual,
        duration_ms = durationMs(t0),
    })
end

function Tools.getCasualMessage()
    Tools.preloadMessages()
    local pool = Tools._casualCache or {}
    if #pool == 0 then return "hi" end
    return pool[math.random(1, #pool)].text
end

local function _classifyBrand(text)
    local t = string.lower(text or "")
    if t:find("adoptme%.pw") or t:find("adopt%-me%.pw") or t:find("adopt%s*me%s*%.%s*pw") then
        return "adoptme"
    end
    return "rblx"
end

function Tools.getAdMessage()
    Tools.preloadMessages()
    local pool = Tools._adsCache or {}
    if #pool == 0 then return nil end

    -- балансировка 50/50 по бренду: rblx.pw / adoptme.pw
    local rblx, adoptme = {}, {}
    for _, m in ipairs(pool) do
        if _classifyBrand(m.text) == "adoptme" then
            table.insert(adoptme, m)
        else
            table.insert(rblx, m)
        end
    end

    local chosenBrand, chosenPool
    if math.random() < 0.5 then
        chosenBrand = (#adoptme > 0) and "adoptme" or "rblx"
        chosenPool  = (#adoptme > 0) and adoptme   or rblx
    else
        chosenBrand = (#rblx > 0) and "rblx" or "adoptme"
        chosenPool  = (#rblx > 0) and rblx   or adoptme
    end
    if #chosenPool == 0 then return nil end

    local row = chosenPool[math.random(1, #chosenPool)]
    Tools.logDebug("Ad выбран по бренду", {
        category    = "AD",
        brand       = chosenBrand,
        pool_rblx   = #rblx,
        pool_adopt  = #adoptme,
        message_id  = row.id,
    })
    return { id = row.id, message = row.text, cooldown_minutes = row.cooldown_minutes, brand = chosenBrand }
end

function Tools.markAdMessageUsed(messageId, cooldownMinutes)
    cooldownMinutes = cooldownMinutes or 60
    Tools.sbRpc("rpc_message_used", {
        p_message_id       = messageId,
        p_bot_id           = Tools.bot_id,
        p_cooldown_minutes = cooldownMinutes,
    })
    Tools.logInfo("Сообщение использовано", {
        category   = "AD",
        message_id = messageId,
        cooldown   = cooldownMinutes,
    })
end

function Tools.deactivateAdMessage(messageId)
    Tools.sbRpc("rpc_message_filtered", {
        p_message_id = messageId,
        p_bot_id     = Tools.bot_id,
    })
    Tools.logWarning("Сообщение деактивировано фильтром", {
        category   = "AD",
        message_id = messageId,
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
        session_id   = Tools.session_id,
        server_id    = serverId,
        place_id     = placeId,
        player_count = playerCount,
    })
end

-- ============================================================
-- LOCAL CURSOR
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
-- LOCAL VISITED JOBIDS (быстрый чек коллизии до ответа Supabase)
-- ============================================================
local function _visitedFile(placeId)
    return "visited_" .. tostring(placeId) .. ".json"
end

function Tools.loadLocalVisited(placeId)
    local check = isfile or isfile_custom or (syn and syn.is_file)
    local read  = readfile or read_file or (syn and syn.read_file)
    if not check or not read then return {} end
    local fn = _visitedFile(placeId)
    local ok, exists = pcall(check, fn)
    if not (ok and exists) then return {} end
    local rok, raw = pcall(read, fn)
    if not (rok and raw and raw ~= "") then return {} end
    local dok, data = pcall(function() return HttpService:JSONDecode(raw) end)
    if not (dok and type(data) == "table") then return {} end
    -- очистка старше 12 часов
    local cutoff = os.time() - 12 * 3600
    local cleaned = {}
    for jid, ts in pairs(data) do
        if type(ts) == "number" and ts > cutoff then cleaned[jid] = ts end
    end
    return cleaned
end

function Tools.saveLocalVisited(placeId, tbl)
    local write = writefile or write_file or (syn and syn.write_file)
    if not write then return false end
    return pcall(write, _visitedFile(placeId), HttpService:JSONEncode(tbl))
end

function Tools.markJobIdVisitedLocal(placeId, jobId)
    if not jobId or jobId == "" then return end
    local cur = Tools.loadLocalVisited(placeId)
    cur[jobId] = os.time()
    Tools.saveLocalVisited(placeId, cur)
end

function Tools.isJobIdVisitedLocal(placeId, jobId)
    if not jobId or jobId == "" then return false end
    local cur = Tools.loadLocalVisited(placeId)
    return cur[jobId] ~= nil
end

-- ============================================================
-- SERVER POOL (общий кэш через Supabase)
-- ============================================================
function Tools.pickServerFromPool(placeId, minPlayers, maxPlayers)
    if not Tools.bot_id then return nil end
    local data = Tools.sbRpc("rpc_pick_server", {
        p_place_id    = placeId,
        p_bot_id      = Tools.bot_id,
        p_min_players = minPlayers or Tools.minPlayersPreferred,
        p_max_players = maxPlayers or Tools.maxPlayersAllowed,
        p_visited_hrs = 12,
    })
    if data and type(data) == "table" and data[1] and data[1].server_id then
        return data[1]
    end
    return nil
end

function Tools.refreshServerPool(placeId, force)
    -- проверяем возраст пула — если свежий, не тратим API-квоту
    if not force then
        local age = Tools.sbRpc("rpc_pool_age_seconds", { p_place_id = placeId })
        if type(age) == "number" and age < 60 then
            Tools.logDebug("Пул свежий, refresh пропущен",
                { category = "POOL", age_seconds = age })
            return false
        end
    end

    local t0 = tick()
    local url = string.format(
        "https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Desc&limit=100&excludeFullGames=true",
        placeId
    )
    local ok, resp = pcall(function() return httprequest({ Url = url }) end)
    if not ok or not resp or resp.StatusCode ~= 200 then
        Tools.logWarning("Refresh пула: HTTP ошибка", {
            category    = "POOL",
            status      = resp and resp.StatusCode or "no_response",
            duration_ms = durationMs(t0),
        })
        return false
    end

    local data = HttpService:JSONDecode(resp.Body)
    if not (data and data.data and #data.data > 0) then return false end

    -- передаём массив целиком в RPC
    local count = Tools.sbRpc("rpc_upsert_pool", {
        p_place_id = placeId,
        p_servers  = data.data,
    })
    Tools.logInfo("Пул серверов обновлён", {
        category    = "POOL",
        fetched     = #data.data,
        upserted    = count,
        duration_ms = durationMs(t0),
    })
    return true
end

function Tools.startPoolRefresher(placeId, intervalSec)
    intervalSec = intervalSec or 90
    task.spawn(function()
        -- стартовый джиттер 0-30с, чтобы боты не били API одновременно
        task.wait(math.random() * 30)
        while Tools.enabled do
            pcall(Tools.refreshServerPool, placeId, false)
            -- jitter в основном цикле: ±30%
            task.wait(intervalSec * (0.85 + math.random() * 0.30))
        end
    end)
end

-- ============================================================
-- FAST SERVER HOP (новая основная реализация)
-- ============================================================
function Tools.fastServerHop()
    if not Tools.isEnabled() then return false end
    local hopStart = tick()
    Tools.logInfo("Старт fast hop", {
        category    = "HOP",
        place_id    = Tools.placeId,
        current_job = game.JobId,
    })

    -- 1. Очередь скрипта при следующем телепорте
    if queueFunc and not scriptQueued and Tools.scriptUrl ~= "" then
        pcall(function()
            queueFunc('loadstring(game:HttpGet("'
                .. Tools.scriptUrl .. '?t=' .. tick() .. '"))()')
        end)
        scriptQueued = true
    end

    -- 2. Попытка взять из пула — нулевая нагрузка на Roblox API
    local picked = Tools.pickServerFromPool(Tools.placeId,
        Tools.minPlayersPreferred, Tools.maxPlayersAllowed)
    if picked and picked.server_id then
        Tools.logInfo("Сервер выбран из пула", {
            category    = "HOP",
            server_id   = picked.server_id,
            players     = picked.player_count,
            duration_ms = durationMs(hopStart),
        })
        Tools.markServerVisited(picked.server_id, Tools.placeId, picked.player_count)
        Tools.markJobIdVisitedLocal(Tools.placeId, picked.server_id)
        Tools.bumpSession("hops")
        pcall(Tools._flushLogs)
        local tpOk = pcall(function()
            TeleportService:TeleportToPlaceInstance(Tools.placeId, picked.server_id, player)
        end)
        if tpOk then return true end
        Tools.logWarning("TeleportToPlaceInstance провалился, fallback на reroll",
            { category = "HOP", server_id = picked.server_id })
    else
        Tools.logDebug("Пул пуст или нет подходящих — reroll-режим",
            { category = "HOP" })
    end

    -- 3. Reroll: Roblox сам выбирает случайный публичный сервер
    --    Если попадём на тот же job — стартовая проверка в use_tools мгновенно сделает повтор.
    Tools.markJobIdVisitedLocal(Tools.placeId, game.JobId)
    Tools.bumpSession("hops")

    -- параллельно — если пул был пуст, инициируем refresh для следующих ботов
    if not picked then
        task.spawn(function() pcall(Tools.refreshServerPool, Tools.placeId, true) end)
    end

    Tools.logInfo("Reroll teleport (без jobId)", {
        category    = "HOP",
        duration_ms = durationMs(hopStart),
    })
    pcall(Tools._flushLogs)
    local rerollOk, rerollErr = pcall(function()
        TeleportService:Teleport(Tools.placeId, player)
    end)
    if not rerollOk then
        Tools.logError("Reroll teleport провалился", {
            category = "HOP",
            error    = tostring(rerollErr),
        })
        -- крайний fallback — старый API-based hop
        return Tools.serverHop()
    end
    return true
end

-- утилита для use_tools: проверка коллизии перед инициализацией
function Tools.checkCollisionAndRerollIfNeeded(placeId, scriptUrl)
    local jobId = game.JobId
    if not jobId or jobId == "" then return false end
    if not Tools.isJobIdVisitedLocal(placeId, jobId) then return false end

    warn("[Tools] Коллизия: попали на уже посещённый сервер " .. jobId)
    if queueFunc and scriptUrl and scriptUrl ~= "" then
        pcall(function()
            queueFunc('loadstring(game:HttpGet("'
                .. scriptUrl .. '?t=' .. tick() .. '"))()')
        end)
    end
    pcall(function() TeleportService:Teleport(placeId, player) end)
    return true
end

-- ============================================================
-- BOT COMMANDS (управление из админки)
-- ============================================================
function Tools._markCommandResult(cmdId, status, result)
    pcall(function()
        Tools.sb("PATCH", "bot_commands", { id = "eq." .. cmdId }, {
            status       = status,
            completed_at = isoNow(),
            result       = result or {},
        }, { ["Prefer"] = "return=minimal" })
    end)
end

function Tools._handleCommand(cmd)
    local kind = cmd.command
    Tools.logInfo("Получена команда", {
        category   = "CMD",
        command_id = cmd.id,
        kind       = kind,
        payload    = cmd.payload,
    })

    if kind == "stop" then
        Tools.enabled = false
        Tools.botState.running = false
        Tools._markCommandResult(cmd.id, "done", { stopped = true })

    elseif kind == "start" then
        Tools.enabled = true
        Tools.botState.running = true
        Tools._markCommandResult(cmd.id, "done", { started = true })

    elseif kind == "hop" then
        Tools._markCommandResult(cmd.id, "done", { hop_requested = true })
        task.spawn(function() pcall(Tools.serverHop) end)

    elseif kind == "rejoin" then
        Tools._markCommandResult(cmd.id, "done", { rejoin = true })
        task.spawn(function()
            pcall(function()
                if queueFunc and Tools.scriptUrl ~= "" and not scriptQueued then
                    queueFunc('loadstring(game:HttpGet("' .. Tools.scriptUrl .. '?t=' .. tick() .. '"))()')
                    scriptQueued = true
                end
                TeleportService:Teleport(Tools.placeId, player)
            end)
        end)

    elseif kind == "reload" then
        Tools._markCommandResult(cmd.id, "done", { reloaded = true })
        task.spawn(function()
            pcall(function()
                if queueFunc and Tools.scriptUrl ~= "" then
                    queueFunc('loadstring(game:HttpGet("' .. Tools.scriptUrl .. '?t=' .. tick() .. '"))()')
                end
                TeleportService:Teleport(Tools.placeId, player)
            end)
        end)

    elseif kind == "exec" then
        local code = cmd.payload and cmd.payload.code
        if not code then
            Tools._markCommandResult(cmd.id, "error", { error = "no code" })
            return
        end
        local ok, err = pcall(function()
            local fn, perr = loadstring(code)
            if not fn then error(perr) end
            return fn()
        end)
        Tools._markCommandResult(cmd.id, ok and "done" or "error",
            { ok = ok, result = tostring(err) })

    else
        Tools._markCommandResult(cmd.id, "error",
            { error = "unknown command", kind = kind })
    end
end

function Tools.startCommandLoop(intervalSec)
    intervalSec = intervalSec or Tools.commandPollInterval
    if Tools._commandLoopRunning then return end
    Tools._commandLoopRunning = true
    task.spawn(function()
        while Tools._commandLoopRunning do
            task.wait(intervalSec)
            if Tools.bot_id then
                local data = Tools.sb("GET", "bot_commands", {
                    bot_id = "eq." .. Tools.bot_id,
                    status = "eq.pending",
                    select = "id,command,payload",
                    order  = "created_at.asc",
                    limit  = "5",
                })
                if data and type(data) == "table" and #data > 0 then
                    for _, cmd in ipairs(data) do
                        -- мгновенно помечаем picked, чтобы избежать гонок
                        pcall(function()
                            Tools.sb("PATCH", "bot_commands",
                                { id = "eq." .. cmd.id, status = "eq.pending" },
                                { status = "picked", picked_at = isoNow() },
                                { ["Prefer"] = "return=minimal" })
                        end)
                        Tools._handleCommand(cmd)
                    end
                end
            end
        end
    end)
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
    -- ускоренная печать: ~12-18 знаков/сек, эквивалент живого взрослого
    local d = (0.04 + math.random() * 0.04) * (Tools.chatSpeedMul or 1.0)
    if prevChar == " " then d = d + math.random() * 0.02 end
    if char:match("[A-ZА-Я]") then d = d + 0.01 end
    if char:match("[%d%p]")   then d = d + 0.01 end
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
        if Tools.isPlayButtonVisible() then
            Tools.logDebug("PlayButton найден", {
                category    = "UI",
                duration_ms = durationMs(t0),
            })
            return true
        end
        task.wait(0.5)
    end
    Tools.logWarning("PlayButton не найден за таймаут", {
        category = "UI",
        timeout  = timeout,
    })
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
    Tools.logInfo("Клик по PlayButton", { category = "UI", x = cx, y = cy })
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
        if Tools.isAdoptionIslandButtonVisible() then
            Tools.logDebug("Adoption Island найден", {
                category    = "UI",
                duration_ms = durationMs(t0),
            })
            return true
        end
        task.wait(0.5)
    end
    Tools.logWarning("Adoption Island не найден за таймаут", {
        category = "UI",
        timeout  = timeout,
    })
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
        return false, "Кнопка Adoption Island не найдена"
    end

    local pos = btn.AbsolutePosition
    local sz  = btn.AbsoluteSize
    local inset = GuiService:GetGuiInset()
    local cx = pos.X + sz.X / 2
    local cy = pos.Y + sz.Y / 2 + inset.Y

    VirtualInputManager:SendMouseButtonEvent(cx, cy, 0, true,  game, 1)
    task.wait(0.05)
    VirtualInputManager:SendMouseButtonEvent(cx, cy, 0, false, game, 1)
    Tools.logInfo("Клик по Adoption Island", { category = "UI", x = cx, y = cy })
    return true, "Клик выполнен"
end

-- ============================================================
-- CHAT
-- ============================================================
function Tools.sendChat(msg)
    local t0 = tick()
    Tools.randomDelay(0.05, 0.12)
    VirtualInputManager:SendKeyEvent(true,  Enum.KeyCode.Slash, false, game)
    task.wait(0.02 + math.random() * 0.03)
    VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.Slash, false, game)
    Tools.randomDelay(0.08, 0.18)

    local prev = ""
    for i = 1, #msg do
        local ch = msg:sub(i, i)
        VirtualInputManager:SendTextInputCharacterEvent(ch, game)
        task.wait(Tools.getTypeDelay(ch, prev))
        prev = ch
    end

    Tools.randomDelay(0.05, 0.12)
    VirtualInputManager:SendKeyEvent(true,  Enum.KeyCode.Return, false, game)
    task.wait(0.02 + math.random() * 0.02)
    VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.Return, false, game)

    Tools.bumpSession("messages")
    Tools.logInfo("Сообщение отправлено", {
        category    = "CHAT",
        message     = msg,
        length      = #msg,
        duration_ms = durationMs(t0),
    })
end

-- ============================================================
-- CHAT LISTENER
-- ============================================================
Tools.chatMessageBuffer     = {}
Tools.chatBufferMaxSize     = 50
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
                Tools.logInfo("Chat listener подключён (TextChat)", { category = "CHAT_LISTENER" })
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
                Tools.logInfo("Chat listener подключён (Legacy)", { category = "CHAT_LISTENER" })
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

-- Несколько эвристик фильтрации (хеши, звёздочки, замены)
function Tools.isMessageFiltered(messages, hashThreshold)
    hashThreshold = hashThreshold or 3
    for idx, msg in ipairs(messages) do
        -- хеши подряд
        local consec, maxHash = 0, 0
        for i = 1, #msg do
            if msg:sub(i, i) == "#" then
                consec = consec + 1
                if consec > maxHash then maxHash = consec end
            else
                consec = 0
            end
        end
        -- общее количество хешей / звёздочек / [content deleted]
        local hashCount = select(2, msg:gsub("#", ""))
        local starCount = select(2, msg:gsub("%*", ""))
        local hasDeleted = msg:lower():find("content deleted") ~= nil

        if maxHash > hashThreshold or hashCount >= 5 or starCount >= 5 or hasDeleted then
            Tools.logWarning("Фильтрация обнаружена", {
                category     = "FILTER_CHECK",
                message_idx  = idx,
                bad_text     = msg,
                hash_run     = maxHash,
                hash_total   = hashCount,
                star_total   = starCount,
                has_deleted  = hasDeleted,
            })
            return true, msg
        end
    end
    return false, nil
end

function Tools.checkAndDeactivateIfFiltered(adMessageId, waitTime)
    waitTime = waitTime or 2
    local t0 = tick()
    Tools.logDebug("Проверка фильтрации", {
        category   = "FILTER",
        message_id = adMessageId,
        wait_time  = waitTime,
    })
    task.wait(waitTime)

    local recent = Tools.getRecentChatMessages(15)
    Tools.logDebug("Получены сообщения чата", {
        category   = "FILTER",
        count      = #recent,
        sample     = recent[1] or "",
    })

    if #recent == 0 then
        Tools.logWarning("Чат пуст — не могу проверить фильтр",
            { category = "FILTER", message_id = adMessageId })
        return false
    end

    local filtered, badMsg = Tools.isMessageFiltered(recent, 3)
    if filtered then
        Tools.logWarning("Фильтрация подтверждена", {
            category      = "FILTER",
            message_id    = adMessageId,
            filtered_text = badMsg,
            duration_ms   = durationMs(t0),
        })
        if adMessageId then Tools.deactivateAdMessage(adMessageId) end
        return true
    end
    Tools.logInfo("Сообщение прошло без фильтрации", {
        category    = "FILTER",
        message_id  = adMessageId,
        duration_ms = durationMs(t0),
    })
    return false
end

-- ============================================================
-- SERVER HOP
-- ============================================================
function Tools.serverHop()
    local hopStart = tick()
    Tools.logInfo("Старт server hop", {
        category    = "HOP",
        place_id    = Tools.placeId,
        current_job = game.JobId,
    })

    local visited = Tools.getVisitedServers(12)
    local visitedSet = {}
    for _, sid in ipairs(visited) do visitedSet[sid] = true end
    Tools.logDebug("Загружены посещённые сервера", {
        category = "HOP",
        count    = #visited,
    })

    local saved = Tools.getSavedCursor(Tools.placeId)
    local cursor, lastSaved, page = "", "", 1
    if saved then
        cursor    = saved.cursor
        page      = saved.pageNumber
        lastSaved = cursor
        if page >= 20 then
            Tools.logInfo("Сброс курсора (page ≥ 20)",
                { category = "HOP", page = page })
            Tools.clearCursor(Tools.placeId); cursor, page = "", 1
        end
    end

    local minP = Tools.minPlayersPreferred
    local rateLimitCount = 0
    local scanned, candidates = 0, 0

    while true do
        if not Tools.isEnabled() then
            Tools.logInfo("Server hop прерван (disabled)",
                { category = "HOP", duration_ms = durationMs(hopStart) })
            return false
        end

        local url = string.format(
            "https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Desc&limit=100&excludeFullGames=true%s",
            Tools.placeId,
            cursor ~= "" and "&cursor=" .. cursor or ""
        )

        local httpStart = tick()
        local ok, response = pcall(function() return httprequest({ Url = url }) end)
        local httpDur = durationMs(httpStart)

        if ok and response.StatusCode == 200 then
            rateLimitCount = 0
            local data = HttpService:JSONDecode(response.Body)
            local servers = shuffleArray(data.data)
            scanned = scanned + #servers
            Tools.logDebug("Страница серверов получена", {
                category    = "HOP",
                page        = page,
                count       = #servers,
                duration_ms = httpDur,
            })

            for _, server in ipairs(servers) do
                local pCount = server.playing
                local maxP   = server.maxPlayers
                local sid    = server.id
                local free   = maxP - pCount
                local fresh  = not visitedSet[sid]
                local ok1    = pCount >= minP
                local ok2    = free >= 10
                local ok3    = pCount <= Tools.maxPlayersAllowed
                local ok4    = sid ~= game.JobId

                if ok1 and ok2 and ok3 and ok4 and fresh then
                    candidates = candidates + 1
                    Tools.logInfo("Найден подходящий сервер", {
                        category     = "HOP",
                        server_id    = sid,
                        players      = pCount,
                        max_players  = maxP,
                        free_slots   = free,
                        scanned      = scanned,
                        candidates   = candidates,
                        page         = page,
                        search_ms    = durationMs(hopStart),
                    })
                    Tools.markServerVisited(sid, Tools.placeId, pCount)
                    Tools.bumpSession("hops")

                    local tpOk, tpErr = pcall(function()
                        if not scriptQueued and queueFunc then
                            queueFunc('loadstring(game:HttpGet("'
                                .. Tools.scriptUrl .. '?t=' .. tick() .. '"))()')
                            scriptQueued = true
                        end
                        TeleportService:TeleportToPlaceInstance(Tools.placeId, sid, player)
                    end)

                    if tpOk then
                        Tools.logInfo("Телепорт выполнен", {
                            category    = "HOP",
                            server_id   = sid,
                            duration_ms = durationMs(hopStart),
                        })
                        -- ensure logs flushed before teleport убивает поток
                        pcall(Tools._flushLogs)
                        return true
                    else
                        Tools.logWarning("Ошибка телепорта, ищу дальше", {
                            category  = "HOP",
                            server_id = sid,
                            error     = tostring(tpErr),
                        })
                    end
                end
            end

            if data.nextPageCursor then
                cursor = data.nextPageCursor; page = page + 1
                if page > 20 then
                    Tools.logInfo("Лимит страниц достигнут, сброс",
                        { category = "HOP", page = page })
                    Tools.clearCursor(Tools.placeId); cursor, page = "", 1
                elseif cursor ~= "" and cursor ~= lastSaved then
                    Tools.saveCursor(Tools.placeId, cursor, page)
                    lastSaved = cursor
                end
            else
                Tools.logInfo("Конец списка серверов, рестарт",
                    { category = "HOP", scanned = scanned })
                Tools.clearCursor(Tools.placeId); cursor, page = "", 1
            end

        elseif ok and response.StatusCode == 429 then
            rateLimitCount = rateLimitCount + 1
            local wait = math.min(10 * (2 ^ (rateLimitCount - 1)), 120)
            Tools.logWarning("Rate limit от Roblox API", {
                category     = "HOP",
                wait_seconds = wait,
                attempt      = rateLimitCount,
            })
            for _ = 1, wait do
                if not Tools.isEnabled() then return false end
                task.wait(1)
            end
        else
            Tools.logError("HTTP ошибка при загрузке серверов", {
                category    = "HOP",
                status      = response and response.StatusCode or "no_response",
                duration_ms = httpDur,
            })
            task.wait(5)
        end
    end
end

-- ============================================================
-- AUTO-RECONNECT
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
                        Tools.logWarning("Реконнект: клик по ReconnectButton",
                            { category = "RECONNECT" })
                        clickBtn(btn); return
                    end
                end
            end
            for _, obj in pairs(cg:GetDescendants()) do
                if obj:IsA("TextButton") or obj:IsA("ImageButton") then
                    local t = string.lower(obj.Text or obj.Name or "")
                    if t:find("reconnect") or t:find("переподключ") then
                        Tools.logWarning("Реконнект: клик через сканирование", {
                            category    = "RECONNECT",
                            button_text = obj.Text or "",
                            button_name = obj.Name,
                        })
                        clickBtn(obj); return
                    end
                end
            end
        end)
    end

    pcall(function()
        GuiService.ErrorMessageChanged:Connect(function()
            local code = GuiService:GetErrorCode()
            Tools.logWarning("Ошибка соединения", {
                category   = "RECONNECT",
                error_code = tostring(code),
            })
            if noReconnect[code] then
                Tools.logWarning("Реконнект пропущен: фатальная ошибка",
                    { category = "RECONNECT", error_code = tostring(code) })
                return
            end
            task.spawn(function()
                task.wait(1.5)
                local n = 0
                while isErrorVisible() and n < 20 do
                    n = n + 1
                    tryClickReconnect()
                    task.wait(3)
                end
                if n > 0 and not isErrorVisible() then
                    Tools.logInfo("Реконнект успешен",
                        { category = "RECONNECT", attempts = n })
                end
            end)
        end)
    end)

    -- Резервный медленный поллинг (раз в 10с вместо 3, чтобы не нагружать)
    task.spawn(function()
        while true do
            task.wait(10)
            if isErrorVisible() then tryClickReconnect() end
        end
    end)
end

-- ============================================================
-- DIAGNOSTICS (опционально вызывается из use_tools)
-- ============================================================
function Tools.logSystemSnapshot(reason)
    local fps, ping = 0, 0
    pcall(function()
        local items = Stats.NetworkStats:GetChildren()
        for _, it in ipairs(items) do
            if it.Name == "Data Ping" then ping = it:GetValue() end
        end
        fps = math.floor(1 / RunService.Heartbeat:Wait())
    end)
    Tools.logInfo("Снапшот системы", {
        category    = "DIAG",
        reason      = reason or "snapshot",
        ping_ms     = math.floor(ping),
        place_id    = game.PlaceId,
        job_id      = game.JobId,
        player_cnt  = #Players:GetPlayers(),
    })
end

return Tools
