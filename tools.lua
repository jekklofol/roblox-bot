-- ============================================================
-- Reklamshiki Tools (Supabase edition, v3)
--   * async batch-логирование
--   * sessions lifecycle + atomic RPC counters
--   * ускоренный чат
--   * bot_commands polling (управление из админки)
--   * расширенная телеметрия
-- ============================================================

-- СВОЙ Postgres+PostgREST на нашем сервере (ушли с Supabase 2026-06-27 — лимит трафика).
-- Тот же REST-API, поэтому Tools.sb не меняется, только адрес+ключ. См. REKLAMSHIKI §6.
local SUPABASE_URL      = "https://212-113-104-183.sslip.io"
local SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoiYW5vbiIsImlzcyI6InJla2xhbXNoaWtpIn0.ndQK7X-ZmTu4fUvpNbI-H8nkqDHGNIQEg5vBK1WBES4"

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
    minServerDwell      = 20,   -- минимум секунд на сервере до любого hop (анти-флуд телепортов)
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

-- Порог логирования в базу (v3.23): DEBUG-шум (Heartbeat, «Пул свежий», «Ad выбран»
-- и т.п.) НЕ пишем — чтобы не нагружать Supabase и не раздувать logs. Важное
-- (INFO+: реклама, хопы, реконнекты, ошибки) пишется. Меняется через remote config
-- 'min_log_level' (можно временно опустить до DEBUG для отладки) или Tools.minLogLevel.
Tools.minLogLevel = Tools.minLogLevel or "INFO"
local LOG_RANK = { DEBUG = 1, INFO = 2, WARNING = 3, ERROR = 4, CRITICAL = 5 }

function Tools.sendLog(level, message, context)
    local rank    = LOG_RANK[level or "INFO"] or 2
    local minRank = LOG_RANK[Tools.minLogLevel] or 2
    if rank < minRank then return end   -- ниже порога — в базу не пишем
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
    Tools._serverLoadTick = tick()   -- момент загрузки скрипта на этом сервере (для детекта «застрял»)
    Tools._stuckLogged    = false

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

-- АНТИ-AFK: Roblox шлёт Player.Idled после ~20 мин без «настоящего» ввода и затем
-- кикает за неактивность. Эмулируем ввод (стандартный приём VirtualUser), чтобы кик
-- не наступал. Здоровый бот и так прыгает (<420с = новый VM), но это страхует
-- застрявших, пока их разруливает watchdog-цикл / честный пульс.
function Tools.startAntiAfk()
    if Tools._antiAfkHooked then return end
    Tools._antiAfkHooked = true
    pcall(function()
        local VirtualUser = game:GetService("VirtualUser")
        player.Idled:Connect(function()
            pcall(function()
                VirtualUser:CaptureController()
                VirtualUser:ClickButton2(Vector2.new())
            end)
            Tools.logWarning("Anti-AFK: Player.Idled — эмулирую ввод", { category = "BOT" })
        end)
    end)
end

-- ЧЕСТНЫЙ ПУЛЬС: дольше этого на одном сервере (один VM, без перезагрузки скрипта) =
-- бот застрял (hard-cap 360с + fallback 420с должны были его увести). 600с с запасом
-- выше нормы (dwell ≤260с). Тогда heartbeat ОСТАНАВЛИВАЕТСЯ → last_seen стареет →
-- внешний мозг (watchdog.ps1 / termux: last_seen>180с = мёртв) перезапускает аккаунт.
-- Без этого зомби слал бы пульс вечно и выглядел «живым» → авто-подъём не реагировал.
Tools.stuckHeartbeatSec = Tools.stuckHeartbeatSec or 600

function Tools.startHeartbeat(intervalSec)
    intervalSec = intervalSec or 60
    if Tools._heartbeatRunning then return end
    Tools._heartbeatRunning = true
    task.spawn(function()
        while Tools.enabled and Tools._heartbeatRunning do
            task.wait(intervalSec)
            -- застрял на одном сервере дольше нормы → перестаём врать пульсом
            local loadTick = Tools._serverLoadTick
            if loadTick and (tick() - loadTick) > Tools.stuckHeartbeatSec then
                if not Tools._stuckLogged then
                    Tools._stuckLogged = true
                    Tools.logCritical("Застрял на сервере >" .. Tools.stuckHeartbeatSec
                        .. "с — глушу heartbeat, отдаю внешнему авто-подъёму", {
                        category = "WATCHDOG",
                        stuck_sec = math.floor(tick() - loadTick),
                    })
                    pcall(Tools._flushLogs)
                end
                Tools._heartbeatRunning = false
                break   -- last_seen перестанет обновляться → termux/watchdog перезапустит
            end
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
    for _, m in ipairs(data) do
        if m.type == "ad" then
            -- держим ВСЕ активные (cooldown учитываем при выборе в getAdMessage через LRU,
            -- чтобы пул никогда не «кончался» и не сваливался в хардкод-фоллбэк)
            table.insert(ads, m)
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

-- классификация бренда по тексту. Сепараторы домена разнятся: adoptme.pw /
-- adoptme-pw / adoptme,pw / adoptmepw / "a d o p t m e p w" / "adopt me dot pw".
-- Приём: убираем "dot"-обфускацию, затем ВСЁ кроме букв → остаётся "adoptmepw"/"rblxpw".
local function _classifyBrand(text)
    local t = string.lower(text or "")
    t = t:gsub("dot", "")                 -- "adopt me dot pw" → "...  pw"
    local letters = t:gsub("[^%a]", "")   -- "adoptme . pw"/"a d o p t m e p w" → "adoptmepw"
    if letters:find("adoptmepw", 1, true) then
        return "adoptme"
    end
    return "rblx"
end

function Tools.getAdMessage()
    Tools.preloadMessages()
    local pool = Tools._adsCache or {}
    if #pool == 0 then return nil end

    -- балансировка 90/10 по бренду: rblx.pw (90%) / adoptme.pw (10%)
    local rblx, adoptme = {}, {}
    for _, m in ipairs(pool) do
        if _classifyBrand(m.text) == "adoptme" then
            table.insert(adoptme, m)
        else
            table.insert(rblx, m)
        end
    end

    local chosenBrand, brandPool
    if math.random() < 0.90 and #rblx > 0 then
        chosenBrand, brandPool = "rblx", rblx
    elseif #adoptme > 0 then
        chosenBrand, brandPool = "adoptme", adoptme
    else
        chosenBrand, brandPool = "rblx", rblx
    end
    if #brandPool == 0 then return nil end

    -- доступные = у кого cooldown истёк. Если такие есть — случайное из них.
    -- Если ВСЕ на cooldown (пул исчерпан под нагрузкой) — случайное из всего бренд-пула:
    -- пул НЕ кончается, реклама всегда живая и разнообразная, без хардкод-фоллбэка.
    -- (случайное, а не строгий LRU — чтобы боты со стухшим 180с-кэшем не сходились на одном.)
    local nowIso = isoNow()
    local available = {}
    for _, m in ipairs(brandPool) do
        if not m.cooldown_until or m.cooldown_until < nowIso then
            table.insert(available, m)
        end
    end

    local row, mode
    if #available > 0 then
        row, mode = available[math.random(1, #available)], "fresh"
    else
        row, mode = brandPool[math.random(1, #brandPool)], "recycle"
    end
    if not row then return nil end

    Tools.logDebug("Ad выбран", {
        category       = "AD",
        brand          = chosenBrand,
        mode           = mode,
        pool_rblx      = #rblx,
        pool_adopt     = #adoptme,
        avail_in_brand = #available,
        message_id     = row.id,
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

-- ОХВАТ захода (пишется один раз при уходе с сервера):
--   active_chatters (пол)  = сколько РАЗНЫХ людей реально писали при нас → точно видят чат
--   players_present (потолок) = сколько игроков было рядом
-- среднее ((пол+потолок)/2) считается уже в админке как «оценка охвата».
function Tools.recordReach(serverId)
    local chatters = 0
    for _ in pairs(Tools.visitChatters or {}) do chatters = chatters + 1 end
    local players = 0
    pcall(function() players = #game:GetService("Players"):GetPlayers() end)
    Tools.sbInsert("reach_events", {
        bot_id          = Tools.bot_id,
        session_id      = Tools.session_id,
        server_id       = serverId,
        players_present = players,
        active_chatters = chatters,
    })
    Tools.logInfo("Охват зафиксирован", {
        category = "REACH", players = players, chatters = chatters,
    })
end

-- ============================================================
-- SELF-TEST shadow-mute (детект «нас не слышно»): пара ботов на одном сервере.
-- Конфиг в bot_config (per-bot key='selftest', value JSON {role, marker, secs, jobid}).
-- role=send: бот публикует свой jobid (глоб. key='selftest_anchor') и шлёт метку.
-- role=watch: читает anchor jobid, телепортится туда, слушает, считает, видна ли метка.
-- Метка вида "zq9 rblx dot pw zq9": токен zq9 фильтр не трогает → видно «дошло ли»;
-- средняя часть покажет, режется ли адрес. Оба обходят анти-коллизию (ранний return).
-- ============================================================
function Tools.runSelftest(cfgStr)
    local ok, cfg = pcall(function() return HttpService:JSONDecode(cfgStr) end)
    if not ok or type(cfg) ~= "table" then return end
    local secs   = tonumber(cfg.secs) or 150
    local marker = cfg.marker or "zq9 rblx dot pw zq9"
    Tools.logInfo("SELFTEST старт", { category = "SELFTEST", role = tostring(cfg.role), secs = secs })
    pcall(Tools._flushLogs)

    -- зайти в игру (иначе чат не работает)
    task.wait(3)
    if Tools.waitForPlayButton(20) then Tools.randomDelay(1, 2); pcall(Tools.clickPlayButton) end
    if Tools.waitForAdoptionIslandButton(2) then pcall(Tools.clickAdoptionIslandButton) end
    task.wait(5)

    local function clearMyCfg()
        pcall(function() Tools.sb("DELETE", "bot_config",
            { bot_id = "eq." .. tostring(Tools.bot_id), key = "eq.selftest" }) end)
    end

    if cfg.role == "send" then
        -- публикуем точку встречи (свой текущий jobId)
        pcall(function() Tools.sb("DELETE", "bot_config", { key = "eq.selftest_anchor" }) end)
        pcall(function() Tools.sbInsert("bot_config", { key = "selftest_anchor", value = game.JobId }) end)
        Tools.logCritical("SELFTEST anchor опубликован", { category = "SELFTEST", jobid = game.JobId })
        pcall(Tools._flushLogs)
        local t0 = tick()
        while tick() - t0 < secs do
            pcall(function() Tools.sendChatAsync(marker) end)
            Tools.logInfo("SELFTEST метка отправлена", { category = "SELFTEST", marker = marker })
            task.wait(7)
        end

    elseif cfg.role == "watch" then
        local anchor = cfg.jobid
        if not anchor or anchor == "" then
            local t0 = tick()
            while tick() - t0 < 120 and (not anchor or anchor == "") do
                local rows = Tools.sb("GET", "bot_config",
                    { key = "eq.selftest_anchor", select = "value", limit = "1" })
                if rows and rows[1] and rows[1].value and rows[1].value ~= "" then
                    anchor = rows[1].value
                else
                    task.wait(5)
                end
            end
        end
        if anchor and anchor ~= "" and game.JobId ~= anchor then
            -- сохраняем anchor в свой конфиг и телепортимся; после ТП новый VM продолжит watch тут
            pcall(function()
                Tools.sb("DELETE", "bot_config", { bot_id = "eq." .. tostring(Tools.bot_id), key = "eq.selftest" })
                Tools.sbInsert("bot_config", { bot_id = Tools.bot_id, key = "selftest",
                    value = HttpService:JSONEncode({ role = "watch", jobid = anchor, marker = marker, secs = secs }) })
            end)
            Tools.logCritical("SELFTEST watch → телепорт к anchor", { category = "SELFTEST", anchor = anchor })
            pcall(Tools._flushLogs)
            pcall(function() TeleportService:TeleportToPlaceInstance(Tools.placeId, anchor, player) end)
            task.wait(30)   -- если ТП не сработал — упадём ниже к очистке
            return
        end
        -- мы на anchor-сервере → слушаем чат
        local seen = {}
        local conn
        pcall(function()
            conn = game:GetService("TextChatService").MessageReceived:Connect(function(m)
                seen[#seen + 1] = tostring(m.Text or "")
            end)
        end)
        Tools.logCritical("SELFTEST watch слушает на anchor", { category = "SELFTEST", jobid = game.JobId })
        local t0 = tick()
        while tick() - t0 < secs do task.wait(3) end
        pcall(function() if conn then conn:Disconnect() end end)
        local tokenHits, hashHits = 0, 0
        local samples = {}
        for _, txt in ipairs(seen) do
            if string.find(txt, "zq9", 1, true) then tokenHits = tokenHits + 1; samples[#samples+1] = txt end
            if string.find(txt, "###", 1, true) then hashHits = hashHits + 1 end
        end
        Tools.logCritical("SELFTEST РЕЗУЛЬТАТ", {
            category    = "SELFTEST",
            total_seen  = #seen,
            token_hits  = tokenHits,   -- >0 = метку видно (НЕ shadow-mute)
            hash_msgs   = hashHits,
            verdict     = (tokenHits == 0) and "NOT_SEEN(shadow-mute?)"
                          or "SEEN",
            samples     = table.concat(samples, " | "):sub(1, 500),
        })
        pcall(Tools._flushLogs)
    end

    -- очистка конфигов и возврат в норму
    clearMyCfg()
    pcall(function() Tools.sb("DELETE", "bot_config", { key = "eq.selftest_anchor" }) end)
    pcall(Tools._flushLogs)
    task.wait(2)
    pcall(Tools.fastServerHop)
end

-- ============================================================
-- MASS MUTE-CHECK (v3.23): массово проверяем, кто из ботов в shadow-mute.
-- Конфиг bot_config per-bot key='mutecheck' value JSON {role:'judge'|'probe', secs}.
--   judge: садится на сервер, публикует jobid (key='mutecheck_anchor'), слушает чат,
--          и на каждое услышанное "mc-<username>" ставит этому боту chat_muted=false.
--   probe: читает anchor, телепортится туда, помечает СЕБЯ chat_muted=true (по умолчанию
--          в бане), шлёт "mc-<своёимя>" несколько раз. Если judge услышал — переключит на false.
-- Итог: услышанные = не в бане; неуслышанные = в бане. Оба обходят анти-коллизию.
-- ============================================================
function Tools.runMuteCheck(cfgStr)
    local ok, cfg = pcall(function() return HttpService:JSONDecode(cfgStr) end)
    if not ok or type(cfg) ~= "table" then return end
    local secs = tonumber(cfg.secs) or 150
    Tools.logCritical("MUTECHECK старт", { category = "MUTECHECK", role = tostring(cfg.role), secs = secs })
    pcall(Tools._flushLogs)

    task.wait(3)
    if Tools.waitForPlayButton(20) then Tools.randomDelay(1, 2); pcall(Tools.clickPlayButton) end
    if Tools.waitForAdoptionIslandButton(2) then pcall(Tools.clickAdoptionIslandButton) end
    task.wait(5)

    local function clearMine()
        pcall(function() Tools.sb("DELETE", "bot_config",
            { bot_id = "eq." .. tostring(Tools.bot_id), key = "eq.mutecheck" }) end)
    end

    if cfg.role == "judge" then
        pcall(function() Tools.sb("DELETE", "bot_config", { key = "eq.mutecheck_anchor" }) end)
        pcall(function() Tools.sbInsert("bot_config", { key = "mutecheck_anchor", value = game.JobId }) end)
        Tools.logCritical("MUTECHECK судья готов (anchor)", { category = "MUTECHECK", jobid = game.JobId })
        pcall(Tools._flushLogs)
        local heard = {}
        local conn
        pcall(function()
            conn = game:GetService("TextChatService").MessageReceived:Connect(function(m)
                local txt = tostring(m.Text or "")
                local name = string.match(txt, "mc%-([%w_]+)")
                if name and not heard[name] then
                    heard[name] = true
                    -- услышали этого бота → он НЕ в бане
                    pcall(function()
                        Tools.sb("PATCH", "bots", { username = "eq." .. name },
                            { chat_muted = false, mute_checked_at = isoNow() }, { ["Prefer"] = "return=minimal" })
                    end)
                    Tools.logInfo("MUTECHECK услышан (не в бане)", { category = "MUTECHECK", name = name })
                end
            end)
        end)
        local t0 = tick()
        while tick() - t0 < secs do task.wait(3) end
        pcall(function() if conn then conn:Disconnect() end end)
        Tools.logCritical("MUTECHECK судья закончил", { category = "MUTECHECK", heard_count = (function() local n=0 for _ in pairs(heard) do n=n+1 end return n end)() })

    elseif cfg.role == "probe" then
        -- найти anchor
        local anchor
        local t0 = tick()
        while tick() - t0 < 120 and not anchor do
            local rows = Tools.sb("GET", "bot_config", { key = "eq.mutecheck_anchor", select = "value", limit = "1" })
            if rows and rows[1] and rows[1].value and rows[1].value ~= "" then anchor = rows[1].value
            else task.wait(5) end
        end
        -- если якорь так и не появился — НЕ шлём со своего сервера (иначе ложный «бан»).
        if not anchor then
            Tools.logCritical("MUTECHECK probe: anchor не найден за 120с — отмена (не помечаю)",
                { category = "MUTECHECK" })
            clearMine(); pcall(Tools._flushLogs); task.wait(2); pcall(Tools.fastServerHop)
            return
        end
        if game.JobId ~= anchor then
            pcall(function() TeleportService:TeleportToPlaceInstance(Tools.placeId, anchor, player) end)
            task.wait(30)
            return  -- после ТП новый VM перечитает конфиг и продолжит probe тут
        end
        -- ПОДТВЕРЖДЕНО на сервере судьи (game.JobId == anchor): помечаем «в бане по
        -- умолчанию» и шлём метку. Если судья её услышит — снимет флаг (chat_muted=false).
        pcall(function()
            Tools.sb("PATCH", "bots", { id = "eq." .. tostring(Tools.bot_id) },
                { chat_muted = true, mute_checked_at = isoNow() }, { ["Prefer"] = "return=minimal" })
        end)
        local marker = "mc-" .. tostring(player.Name)
        Tools.logCritical("MUTECHECK probe шлёт метку", { category = "MUTECHECK", marker = marker, jobid = game.JobId })
        for _ = 1, 6 do
            pcall(function() Tools.sendChatAsync(marker) end)
            task.wait(6)
        end
    end

    clearMine()
    pcall(function() if cfg.role == "judge" then Tools.sb("DELETE", "bot_config", { key = "eq.mutecheck_anchor" }) end end)
    pcall(Tools._flushLogs)
    task.wait(2)
    pcall(Tools.fastServerHop)
end

-- ============================================================
-- ТЕСТ: может ли Delta слать АВТОРИЗОВАННЫЕ запросы к roblox.com (от имени залогиненного
-- аккаунта)? Если да — бот сможет менять Roblox-аватар прямо из игры (автоматизация
-- скинов на телефонах, без кук/логина с ПК). Включается конфигом `robloxtest`.
-- ============================================================
function Tools.testRobloxAuth()
    Tools.logCritical("RBXTEST старт", { category = "RBXTEST", uid = player and player.UserId })
    pcall(Tools._flushLogs)
    -- пробуем ВСЕ HTTP-функции экзекутора: некоторые САМИ прикладывают куку roblox.com
    -- (тогда запрос авторизован → аватар менять можно). httprequest обычно «чистый» (без куки).
    -- ссылки на несуществующие глобалы = nil (в Lua это не ошибка), syn/fluxus — через and.
    local candidates = {
        { name = "request",        fn = request },
        { name = "http_request",   fn = http_request },
        { name = "httprequest",    fn = httprequest },
        { name = "syn.request",    fn = syn and syn.request },
        { name = "fluxus.request", fn = fluxus and fluxus.request },
        { name = "http.request",   fn = http and http.request },
    }
    for _, c in ipairs(candidates) do
        if type(c.fn) == "function" then
            local ok, resp = pcall(c.fn, {
                Url = "https://users.roblox.com/v1/users/authenticated", Method = "GET",
            })
            local code = (ok and resp and (resp.StatusCode or resp.Status or resp.status)) or 0
            local raw  = ok and resp and (resp.Body or resp.body)
            local body = raw and tostring(raw):sub(1, 140) or (ok and "no_body" or "pcall_fail")
            -- code 200 + наш id в теле = функция авторизована (то что ищем)
            Tools.logCritical("RBXTEST fn", { category = "RBXTEST", fn = c.name, code = code, body = body })
        else
            Tools.logCritical("RBXTEST fn", { category = "RBXTEST", fn = c.name, code = "НЕТ_ФУНКЦИИ" })
        end
        pcall(Tools._flushLogs)
        task.wait(0.5)
    end
end

-- ============================================================
-- РАЗВЕДКА «ОДЕВАЛКИ» Adopt Me: бот заходит в игру и выгружает в логи структуру GUI
-- (имена всех кнопок + элементы, похожие на dress/customize) — чтобы понять, по чему
-- кликать для автокастомизации. НИЧЕГО не меняет. Включается конфигом `dressrecon`.
-- ============================================================
function Tools.runDressRecon()
    Tools.logCritical("DRESS recon старт", { category = "DRESS" })
    pcall(Tools._flushLogs)
    task.wait(3)
    if Tools.waitForPlayButton(20) then Tools.randomDelay(1, 2); pcall(Tools.clickPlayButton) end
    task.wait(7)  -- дать прогрузиться HUD
    local pg = player and player:FindFirstChild("PlayerGui")
    if not pg then
        Tools.logCritical("DRESS: нет PlayerGui", { category = "DRESS" })
        task.wait(2); pcall(Tools.fastServerHop); return
    end

    -- универсальный клик по GUI-объекту (как clickPlayButton: эмуляция мыши + fire)
    local function clickObj(obj)
        if not obj then return false end
        local pos, sz = obj.AbsolutePosition, obj.AbsoluteSize
        local inset = GuiService:GetGuiInset()
        local cx = pos.X + sz.X / 2
        local cy = pos.Y + sz.Y / 2 + inset.Y
        pcall(function()
            VirtualInputManager:SendMouseButtonEvent(cx, cy, 0, true, game, 1); task.wait(0.06)
            VirtualInputManager:SendMouseButtonEvent(cx, cy, 0, false, game, 1)
        end)
        pcall(function() obj.MouseButton1Click:Fire() end)
        pcall(function() obj:Activate() end)
        return true
    end

    -- 1) найти и кликнуть кнопку DressUp
    local dressBtn
    for _, d in ipairs(pg:GetDescendants()) do
        if d:IsA("GuiButton") and d.Name == "DressUp" then dressBtn = d; break end
    end
    Tools.logCritical("DRESS btn", { category = "DRESS", found = dressBtn ~= nil,
        path = dressBtn and dressBtn:GetFullName():sub(1, 200) or "nil" })
    if dressBtn then clickObj(dressBtn); task.wait(3.5) end

    -- 2) открылся ли AvatarEditorApp
    local ae = pg:FindFirstChild("AvatarEditorApp")
    Tools.logCritical("DRESS editor", { category = "DRESS", exists = ae ~= nil,
        enabled = ae and ae.Enabled or false })
    if not ae then Tools.logCritical("DRESS конец (нет редактора)", {category="DRESS"}); task.wait(2); pcall(Tools.fastServerHop); return end

    -- 3) кликнуть именно категорию ВОЛОС (приоритет hair → all_shirts → all_faces)
    local catBtn
    for _, want in ipairs({ "hair", "all_shirts", "all_faces" }) do
        for _, d in ipairs(ae:GetDescendants()) do
            if d:IsA("GuiButton") and d.Name == want then catBtn = d; break end
        end
        if catBtn then break end
    end
    if catBtn then
        Tools.logCritical("DRESS catBtn", { category = "DRESS", name = catBtn.Name, path = catBtn:GetFullName():sub(1, 200) })
        clickObj(catBtn); task.wait(3.5)
    else
        Tools.logCritical("DRESS catBtn НЕ найден", { category = "DRESS" })
    end

    -- 4) дамп ПРЕДМЕТОВ внутри категории: ScrollingFrame НЕ из CategorySlider, с >=4 детьми.
    --    Для каждого предмета: имена детей (структура) + признаки price/lock/equipped.
    local dumped = 0
    for _, d in ipairs(ae:GetDescendants()) do
        if d:IsA("ScrollingFrame") and not string.find(d:GetFullName(), "CategorySlider", 1, true) then
            local items = {}
            for _, k in ipairs(d:GetChildren()) do
                if k:IsA("GuiButton") or (k:IsA("Frame") and #k:GetChildren() > 0) then items[#items + 1] = k end
            end
            if #items >= 4 then
                Tools.logCritical("DRESS itemsBox", { category = "DRESS", path = d:GetFullName():sub(1, 170), n = #items })
                for i = 1, math.min(#items, 8) do
                    local k = items[i]
                    local names, price, lock, owned = {}, false, false, false
                    for _, sub in ipairs(k:GetDescendants()) do
                        names[#names + 1] = sub.Name
                        local ln = string.lower(sub.Name)
                        if ln:find("price") or ln:find("cost") or ln:find("bucks") then price = true end
                        if ln:find("lock") or ln:find("premium") then lock = true end
                        if ln:find("owned") or ln:find("equip") or ln:find("check") or ln:find("select") then owned = true end
                    end
                    Tools.logCritical("DRESS item", { category = "DRESS", name = k.Name, class = k.ClassName,
                        price = price, lock = lock, owned = owned, kids = table.concat(names, ","):sub(1, 170) })
                end
                dumped = dumped + 1
                if dumped >= 1 then break end
            end
        end
    end
    Tools.logCritical("DRESS recon2 конец", { category = "DRESS", scrolls = dumped })
    pcall(Tools._flushLogs)
    task.wait(2)
    pcall(Tools.fastServerHop)
end

-- ============================================================
-- ИИ-ЧАТ РЕЖИМ (DeepSeek через наш сервис). Поведение «живого игрока»:
-- бот слушает чат, изредка и к месту отвечает через LLM, ещё реже роняет сайт.
-- Цель: НЕ спам-профиль (обойти теневой бан) + доверие/конверсия. См. REKLAMSHIKI §4c/§4d.
-- Включается per-bot конфигом bot_config key=`aichat` (любое непустое значение).
-- Нужны глобальные конфиги: `ai_service_url`, `ai_secret`.
-- ============================================================

-- триггеры «темы продажи/робуксов» — повышают шанс ответа и разрешают сайт
local AI_TRIGGERS = {
    "wts", "wtt", "selling", "sell ", "lf ", "robux", "scam", "scammed",
    "trade", "trading", "value", "worth", "wfl", "buy", "money", "cheap", "rich",
    "real money", "irl", "paypal", "cash", "broke", "afford", "rmt", "overpay",
}

local function aiHasTrigger(text)
    local low = string.lower(text or "")
    for _, kw in ipairs(AI_TRIGGERS) do
        if string.find(low, kw, 1, true) then return true end
    end
    return false
end

-- один запрос к нашему ИИ-сервису. Возвращает {reply=..., mentionedSite=bool} или nil/skip.
-- targetName (необяз.) — к кому обращаемся по имени (адресный диалог вместо broadcast).
function Tools.aiChatRequest(contextRows, allowSite, targetName)
    if not httprequest then return nil end
    local url    = Tools.aiServiceUrl
    local secret = Tools.aiSecret
    if not url or url == "" or not secret or secret == "" then return nil end
    local bodyOk, encoded = pcall(function()
        return HttpService:JSONEncode({
            context  = contextRows,
            allowSite = allowSite and true or false,
            selfName = (player and player.Name) or "",
            targetName = targetName or "",
        })
    end)
    if not bodyOk then return nil end
    local ok, resp = pcall(httprequest, {
        Url = url, Method = "POST",
        Headers = { ["Content-Type"] = "application/json", ["x-bot-secret"] = secret },
        Body = encoded,
    })
    if not ok or not resp then return nil end
    local code = resp.StatusCode or resp.Status or 0
    if code < 200 or code >= 300 then
        return nil, code
    end
    local pok, data = pcall(function() return HttpService:JSONDecode(resp.Body or "") end)
    if not pok or type(data) ~= "table" then return nil end
    if data.skip or not data.reply or data.reply == "" then return nil end
    return data
end

-- собрать контекст для LLM: последние N сообщений буфера, в порядке СТАРЫЕ→НОВЫЕ
local function aiBuildContext(n)
    n = n or 10
    local buf = Tools.chatMessageBuffer
    local rows = {}
    -- буфер новые-первыми → берём первые n и переворачиваем
    local take = math.min(n, #buf)
    for i = take, 1, -1 do
        local m = buf[i]
        if m and m.text and m.text ~= "" then
            table.insert(rows, { sender = m.sender or "player", text = m.text })
        end
    end
    return rows
end

-- ПРОФИЛИ СТИЛЯ — боты по-разному БОЛТАЮТ (спокойный / обычный / болтливый), чтобы не
-- слали одинаковое. САЙТ у ВСЕХ упоминается надёжно (в этом смысл ботов) — различается
-- только активность общения. Профиль достаётся боту стабильно по имени (или cfg.profile).
local AI_PROFILES = {
    chill  = { min_gap = 32, chance_trigger = 0.60, chance_idle = 0.12 },  -- спокойный, реже пишет
    normal = { min_gap = 24, chance_trigger = 0.75, chance_idle = 0.20 },
    chatty = { min_gap = 16, chance_trigger = 0.90, chance_idle = 0.32 },  -- активный болтун
}
-- распределение стилей по флоту (примерно поровну — разнообразие). Поменять = эти веса.
local AI_PROFILE_MIX = { { "chill", 34 }, { "normal", 36 }, { "chatty", 30 } }

-- САЙТ у ВСЕХ профилей надёжно (цель ботов = реклама), но НЕ в каждом сообщении (не спам):
local AI_SITE_CHANCE   = 0.75   -- высокий шанс разрешить сайт, когда бот пишет
local AI_SITE_COOLDOWN = 240    -- ~4 мин между упоминаниями сайта → несколько раз за заход

local function aiPickProfile(name)
    local h = 0
    for i = 1, #name do h = (h * 31 + string.byte(name, i)) % 1000003 end
    local r, acc = h % 100, 0
    for _, pw in ipairs(AI_PROFILE_MIX) do
        acc = acc + pw[2]
        if r < acc then return pw[1] end
    end
    return "normal"
end

-- основной цикл ИИ-режима на ОДНОМ сервере (потом hop, как runBot).
function Tools.runAiChat(cfgStr)
    local cfg = {}
    pcall(function() cfg = HttpService:JSONDecode(cfgStr) end)
    if type(cfg) ~= "table" then cfg = {} end

    -- глобальные настройки сервиса
    Tools.aiServiceUrl = Tools.getRemoteConfigValue("ai_service_url") or ""
    Tools.aiSecret     = Tools.getRemoteConfigValue("ai_secret") or ""

    -- ПРОФИЛЬ АКТИВНОСТИ бота: из cfg.profile или стабильно по имени (soft/normal/active).
    -- Распределение по флоту в сторону «мягко/безопасно» (см. AI_PROFILE_MIX).
    local profName = (cfg.profile and AI_PROFILES[cfg.profile]) and cfg.profile
        or aiPickProfile((player and player.Name) or "x")
    local prof = AI_PROFILES[profName] or AI_PROFILES.normal

    -- параметры поведения: дефолты ИЗ ПРОФИЛЯ, любой можно точечно переопределить в cfg
    local dwell        = tonumber(cfg.secs)           or 130   -- сколько сидим на сервере до hop
    local checkMin     = tonumber(cfg.check_min)      or 6     -- как часто заглядываем в чат
    local checkMax     = tonumber(cfg.check_max)      or 11
    local minGap       = tonumber(cfg.min_gap)        or prof.min_gap        -- мин. пауза между нашими репликами
    local siteCooldown = tonumber(cfg.site_cooldown)  or AI_SITE_COOLDOWN    -- пауза после упоминания сайта (глоб., надёжно)
    local chanceTrig   = tonumber(cfg.chance_trigger) or prof.chance_trigger -- шанс ответить на тему-триггер (болтовня)
    local chanceIdle   = tonumber(cfg.chance_idle)    or prof.chance_idle    -- шанс поддержать болтовню
    local siteChance   = tonumber(cfg.site_chance)    or AI_SITE_CHANCE      -- шанс разрешить сайт, когда пишем (глоб., высокий)

    Tools.logCritical("AICHAT старт", {
        category = "AICHAT", dwell = dwell, profile = profName,
        has_url = (Tools.aiServiceUrl ~= ""), has_secret = (Tools.aiSecret ~= ""),
    })
    pcall(Tools._flushLogs)

    if Tools.aiServiceUrl == "" or Tools.aiSecret == "" then
        Tools.logError("AICHAT: нет ai_service_url / ai_secret — выходим", { category = "AICHAT" })
        task.wait(3); pcall(Tools.fastServerHop); return
    end

    -- зайти в игру
    if Tools.waitForPlayButton(20) then Tools.randomDelay(1, 3); pcall(Tools.clickPlayButton) end
    if Tools.waitForAdoptionIslandButton(2) then pcall(Tools.clickAdoptionIslandButton) end
    Tools.connectChatListener()
    Tools.randomDelay(4, 8)

    local serverStart = tick()
    local lastReplyAt = 0
    local lastSiteAt  = -1e9

    while Tools.getBotState().running and (tick() - serverStart) < dwell do
        Tools.randomDelay(checkMin, checkMax)
        if not Tools.getBotState().running then break end

        -- есть ли свежие ЧУЖИЕ сообщения после нашего последнего ответа?
        -- + ловим «цель»: автора САМОГО СВЕЖЕГО горячего сообщения (триггер) — к нему
        -- обратимся по имени (адресный диалог). buf новые-первыми, берём первого по теме.
        local buf = Tools.chatMessageBuffer
        local freshTrigger, freshAny = false, false
        local targetName = nil
        for i = 1, math.min(12, #buf) do
            local m = buf[i]
            if m and not m.isSelf and m.at and m.at > lastReplyAt then
                freshAny = true
                if aiHasTrigger(m.text) then
                    freshTrigger = true
                    if not targetName and m.sender and m.sender ~= "Unknown" then
                        targetName = m.sender
                    end
                end
            end
        end
        if not freshAny then
            -- никто не пишет → иногда бросаем что-то лёгкое (соц.присутствие), но редко
            if (tick() - lastReplyAt) > (minGap * 3) and math.random() < 0.10 then
                freshAny = true
            else
                -- nothing to do this tick
            end
        end
        if freshAny and (tick() - lastReplyAt) >= minGap then
            local chance = freshTrigger and chanceTrig or chanceIdle
            if math.random() < chance then
                -- САЙТ надёжно: разрешаем как только прошёл кулдаун (на тему-триггер —
                -- почти всегда), но НЕ в каждом сообщении (кулдаун) → реклама есть, но не спам.
                local siteReady = (tick() - lastSiteAt) > siteCooldown
                local allowSite = siteReady and (math.random() < (freshTrigger and 0.95 or siteChance))
                local data = Tools.aiChatRequest(aiBuildContext(10), allowSite, targetName)
                if data and data.reply then
                    -- человеческая задержка «печатания» по длине ответа
                    local typeWait = math.clamp(#data.reply / 9, 1.5, 7) + math.random() * 2
                    task.wait(typeWait)
                    if Tools.getBotState().running then
                        Tools.sendChat(data.reply)
                        lastReplyAt = tick()
                        if data.mentionedSite then lastSiteAt = tick() end
                        Tools.logInfo("AICHAT ответ отправлен", {
                            category = "AICHAT", site = data.mentionedSite and true or false,
                        })
                    end
                end
            end
        end
    end

    Tools.logInfo("AICHAT заход завершён, hop", { category = "AICHAT",
        time_on_server = math.floor(tick() - serverStart) })
    pcall(Tools.endSession)
    pcall(Tools._flushLogs)
    task.wait(2)
    pcall(Tools.fastServerHop)
end

-- ============================================================
-- LOCAL CURSOR
-- ============================================================
-- суффикс по UserId — общий для cursor/visited файлов. ОБЪЯВЛЕН ЗДЕСЬ (выше всех,
-- кто его зовёт), иначе cursor-функции резолвят его как nil-глобал → краш (fix C1).
local function _userSuffix()
    local uid = player and player.UserId
    return uid and ("_" .. tostring(uid)) or ""
end

function Tools.getSavedCursor(placeId)
    local check = isfile or isfile_custom or (syn and syn.is_file)
    local read  = readfile or read_file or (syn and syn.read_file)
    if not check or not read then return nil end
    local filename = "cursor_" .. tostring(placeId) .. _userSuffix() .. ".json"
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
    local filename = "cursor_" .. tostring(placeId) .. _userSuffix() .. ".json"
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
    return pcall(del, "cursor_" .. tostring(placeId) .. _userSuffix() .. ".json")
end

-- ============================================================
-- LOCAL VISITED JOBIDS (per-user, быстрый чек коллизии до ответа базы)
-- ============================================================
local function _visitedFile(placeId)
    return "visited_" .. tostring(placeId) .. _userSuffix() .. ".json"
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
        -- было 30 (дефолт): при сварме ботов 30-мин окно "недавно посещён"
        -- покрывало почти весь пул → rpc отдавал nil всем → слепой reroll → funnel.
        p_shared_minutes = 10,
    })
    if data and type(data) == "table" and data[1] and data[1].server_id then
        return data[1]
    end
    return nil
end

-- освободить захваченный (claimed) сервер при уходе — возврат в пул другим ботам сразу,
-- не дожидаясь 10-мин stale recovery. По умолчанию освобождает текущий game.JobId
-- (его мы захватили на прошлом hop'е как этот же bot_id).
function Tools.releaseServer(serverId)
    serverId = serverId or game.JobId
    if not serverId or serverId == "" or not Tools.bot_id then return end
    pcall(function()
        Tools.sbRpc("rpc_release_server", {
            p_place_id  = Tools.placeId,
            p_server_id = serverId,
            p_bot_id    = Tools.bot_id,
        })
    end)
end

-- прыжок на КОНКРЕТНЫЙ свободный сервер (jobId) через атомарный захват rpc_pick.
-- Никакого relaxed/слепого пика — он давал коллизии (два бота брали один сервер).
function Tools.teleportToConcreteServer(reason)
    local picked = Tools.pickServerFromPool(Tools.placeId)
    if not (picked and picked.server_id) or picked.server_id == game.JobId then
        return false
    end
    Tools.markServerVisited(picked.server_id, Tools.placeId, picked.player_count)
    Tools.markJobIdVisitedLocal(Tools.placeId, picked.server_id)
    local ok = Tools.safeTeleport(reason, function()
        TeleportService:TeleportToPlaceInstance(Tools.placeId, picked.server_id, player)
    end, true)
    if ok then
        Tools.logInfo("Прыжок на конкретный свободный сервер", {
            category = "HOP", server_id = picked.server_id, reason = reason,
        })
    else
        Tools.releaseServer(picked.server_id)  -- телепорт не стартовал — вернём захват
    end
    return ok
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
        local status = resp and resp.StatusCode or "no_response"
        -- при 429 — экспоненциальный бэкофф, чтобы не долбить games API
        if status == 429 then
            Tools._poolBackoff = math.min((Tools._poolBackoff or 30) * 2, 600)
            Tools._poolRateLimitedUntil = os.time() + Tools._poolBackoff
            Tools.logWarning("Refresh пула: 429, бэкофф", {
                category     = "POOL",
                backoff_sec  = Tools._poolBackoff,
                duration_ms  = durationMs(t0),
            })
        else
            Tools.logWarning("Refresh пула: HTTP ошибка", {
                category    = "POOL",
                status      = status,
                duration_ms = durationMs(t0),
            })
        end
        return false
    end
    Tools._poolBackoff = 30   -- успех — сбрасываем бэкофф

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
            -- уважаем бэкофф после 429
            local until_ = Tools._poolRateLimitedUntil or 0
            if os.time() >= until_ then
                pcall(Tools.refreshServerPool, placeId, false)
            end
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

    -- 2. Освобождаем сервер, с которого уходим (вернём его в пул другим ботам)
    Tools.releaseServer(game.JobId)

    -- 3. Атомарный захват из пула с ретраями. Никакого слепого матчмейкинга в общем
    --    пути — именно он сваливал рой ботов на один заполняющийся сервер.
    local attempts = 4
    for i = 1, attempts do
        if not Tools.isEnabled() then return false end
        local picked = Tools.pickServerFromPool(Tools.placeId,
            Tools.minPlayersPreferred, Tools.maxPlayersAllowed)
        if picked and picked.server_id and picked.server_id ~= game.JobId then
            Tools.markServerVisited(picked.server_id, Tools.placeId, picked.player_count)
            Tools.markJobIdVisitedLocal(Tools.placeId, picked.server_id)
            Tools.bumpSession("hops")
            Tools.logInfo("Сервер захвачен из пула", {
                category    = "HOP",
                server_id   = picked.server_id,
                players     = picked.player_count,
                attempt     = i,
                duration_ms = durationMs(hopStart),
            })
            local tpOk = Tools.safeTeleport("fast-pool", function()
                TeleportService:TeleportToPlaceInstance(Tools.placeId, picked.server_id, player)
            end)
            if tpOk then return true end
            -- телепорт не стартовал → вернём захват и пробуем снова
            Tools.releaseServer(picked.server_id)
            Tools.logWarning("TeleportToPlaceInstance провалился, ретрай", {
                category = "HOP", server_id = picked.server_id, attempt = i,
            })
        else
            -- пул пуст/разобран свармом — инициируем refresh и ждём с джиттером
            Tools.logDebug("Пул пуст, refresh+wait перед ретраем",
                { category = "HOP", attempt = i })
            task.spawn(function() pcall(Tools.refreshServerPool, Tools.placeId, true) end)
            task.wait(3 + math.random() * 5)
        end
    end

    -- 4. Крайний резерв: пул так и не дал сервер после ретраев. Слепой reroll —
    --    РЕДКИЙ случай (лучше слепой телепорт, чем застрять навсегда), логируем явно.
    Tools.markJobIdVisitedLocal(Tools.placeId, game.JobId)
    Tools.bumpSession("hops")
    Tools.logWarning("Пул исчерпан после ретраев — крайний слепой reroll", {
        category    = "HOP",
        duration_ms = durationMs(hopStart),
    })
    local rerollOk = Tools.safeTeleport("reroll-lastresort", function()
        TeleportService:Teleport(Tools.placeId, player)
    end)
    if not rerollOk then
        Tools.logError("Reroll teleport провалился", { category = "HOP" })
        return Tools.serverHop()   -- крайний fallback — старый API-based hop
    end
    return true
end

-- проверить через Supabase сидит ли другой бот на этом jobId
function Tools.isServerOccupiedByOtherBot(jobId)
    if not jobId or jobId == "" or not Tools.bot_id then return false end
    local res = Tools.sbRpc("rpc_is_server_occupied", {
        p_server_id = jobId,
        p_bot_id    = Tools.bot_id,
    })
    return res == true
end

-- утилита для use_tools: проверка коллизии перед инициализацией
-- НЕ требует bot_id (вызывается до initBot), использует только локальный файл
function Tools.checkCollisionAndRerollIfNeeded(placeId, scriptUrl)
    local jobId = game.JobId
    if not jobId or jobId == "" then return false end
    if not Tools.isJobIdVisitedLocal(placeId, jobId) then return false end

    warn("[Tools] Коллизия (локально): попали на уже посещённый сервер " .. jobId)
    if queueFunc and scriptUrl and scriptUrl ~= "" then
        pcall(function()
            queueFunc('loadstring(game:HttpGet("'
                .. scriptUrl .. '?t=' .. tick() .. '"))()')
        end)
    end
    Tools.safeTeleport("collision-local", function()
        TeleportService:Teleport(placeId, player)
    end, true)
    return true
end

-- лимит reroll'ов: если бот пинг-понгит между серверами — остаётся где есть (per-user)
local function _rerollCounterFile(placeId)
    return "reroll_count_" .. tostring(placeId) .. _userSuffix() .. ".json"
end

function Tools._countRecentRerolls(placeId)
    local check = isfile or isfile_custom or (syn and syn.is_file)
    local read  = readfile or read_file or (syn and syn.read_file)
    if not check or not read then return 0, {} end
    local fn = _rerollCounterFile(placeId)
    local ok, exists = pcall(check, fn)
    if not (ok and exists) then return 0, {} end
    local rok, raw = pcall(read, fn)
    if not (rok and raw and raw ~= "") then return 0, {} end
    local dok, data = pcall(function() return HttpService:JSONDecode(raw) end)
    if not (dok and type(data) == "table") then return 0, {} end
    local cutoff = os.time() - 60
    local recent = {}
    for _, ts in ipairs(data) do
        if type(ts) == "number" and ts > cutoff then table.insert(recent, ts) end
    end
    return #recent, recent
end

function Tools._recordReroll(placeId)
    local write = writefile or write_file or (syn and syn.write_file)
    if not write then return end
    local _, recent = Tools._countRecentRerolls(placeId)
    table.insert(recent, os.time())
    pcall(write, _rerollCounterFile(placeId), HttpService:JSONEncode(recent))
end

-- расширенная проверка после initBot: смотрим в Supabase, не сидит ли другой бот.
-- если да — закрываем сессию, делаем reroll.
function Tools.checkServerSharedWithOtherBot(scriptUrl)
    local jobId = game.JobId
    if not jobId or jobId == "" then return false end

    -- защита от пинг-понга: не больше 5 reroll'ов за 60 секунд
    local recentCount = Tools._countRecentRerolls(Tools.placeId)
    if recentCount >= 5 then
        Tools.logWarning("Достигнут лимит reroll'ов, остаюсь на сервере", {
            category    = "HOP",
            server_id   = jobId,
            reroll_count = recentCount,
        })
        return false
    end

    if not Tools.isServerOccupiedByOtherBot(jobId) then return false end

    Tools.logWarning("Коллизия: на этом сервере сидит более старший бот, reroll", {
        category    = "HOP",
        server_id   = jobId,
        recent_count = recentCount,
    })
    Tools._recordReroll(Tools.placeId)
    Tools.endSession()
    pcall(Tools._flushLogs)
    if queueFunc and scriptUrl and scriptUrl ~= "" then
        pcall(function()
            queueFunc('loadstring(game:HttpGet("'
                .. scriptUrl .. '?t=' .. tick() .. '"))()')
        end)
    end
    -- уходим на КОНКРЕТНЫЙ свободный сервер, а не слепым матчмейкингом
    -- (иначе Roblox снова сваливает на тот же заполняющийся → пинг-понг до лимита reroll'ов)
    if not Tools.teleportToConcreteServer("collision-concrete") then
        Tools.safeTeleport("collision-reroll", function()
            TeleportService:Teleport(Tools.placeId, player)
        end, true)
    end
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
            if queueFunc and Tools.scriptUrl ~= "" and not scriptQueued then
                pcall(function()
                    queueFunc('loadstring(game:HttpGet("' .. Tools.scriptUrl .. '?t=' .. tick() .. '"))()')
                    scriptQueued = true
                end)
            end
            Tools.safeTeleport("cmd-rejoin", function()
                TeleportService:Teleport(Tools.placeId, player)
            end, true)
        end)

    elseif kind == "reload" then
        Tools._markCommandResult(cmd.id, "done", { reloaded = true })
        task.spawn(function()
            if queueFunc and Tools.scriptUrl ~= "" then
                pcall(function()
                    queueFunc('loadstring(game:HttpGet("' .. Tools.scriptUrl .. '?t=' .. tick() .. '"))()')
                end)
            end
            Tools.safeTeleport("cmd-reload", function()
                TeleportService:Teleport(Tools.placeId, player)
            end, true)
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

-- ============================================================
-- TELEPORT-FAIL RECOVERY (v3.15): сервер полон/недоступен → перезаход на ДРУГОЙ.
-- TeleportToPlaceInstance — fire-and-forget; реальный отказ (GameFull и пр.)
-- прилетает асинхронно в TeleportInitFailed. Канон Roblox: GameFull нельзя
-- ретраить на тот же сервер — берём другой; Flooded (рейт-лимит) → ждём дольше.
-- ============================================================
local TP_FAIL_MAX = 5   -- макс. авто-перезаходов подряд (анти-петля); сброс на новом VM

-- Анти-IsTeleporting (v3.17): Roblox держит "teleport in processing" несколько секунд.
-- Если выстрелить новый телепорт слишком рано — ловим IsTeleporting и попадаем в
-- вечный дедлок (watchdog/recovery спамят, зависший TP не разрешается). Поэтому НЕ
-- стартуем телепорты чаще раза в tpMinGap секунд (единый троттлинг в safeTeleport).
Tools.tpMinGap     = 30
Tools._lastTpFireAt = 0

-- закрыть оставшуюся плашку телепорта ("OK"/"Закрыть"). НЕ трогаем диалог
-- дисконнекта с Reconnect — им занимается autoReconnect (и нельзя жать Leave).
function Tools._dismissTeleportPrompt()
    pcall(function()
        local cg      = game:GetService("CoreGui")
        local prompt  = cg:FindFirstChild("RobloxPromptGui")
        local overlay = prompt and prompt:FindFirstChild("promptOverlay")
        if not overlay then return end
        local err  = overlay:FindFirstChild("ErrorPrompt")
        local area = err and err:FindFirstChild("ButtonArea", true)
        if area and (area:FindFirstChild("ReconnectButton") or area:FindFirstChild("Reconnect")) then
            return   -- это дисконнект, не наша плашка
        end
        for _, obj in pairs(overlay:GetDescendants()) do
            if obj:IsA("TextButton") or obj:IsA("ImageButton") then
                local t = string.lower((obj.Text or "") .. " " .. obj.Name)
                if t:find("ok") or t:find("close") or t:find("закры") or t:find("dismiss") then
                    local pos, sz = obj.AbsolutePosition, obj.AbsoluteSize
                    local inset = GuiService:GetGuiInset()
                    local cx = pos.X + sz.X / 2
                    local cy = pos.Y + sz.Y / 2 + inset.Y
                    pcall(function()
                        VirtualInputManager:SendMouseButtonEvent(cx, cy, 0, true,  game, 1)
                        task.wait(0.05)
                        VirtualInputManager:SendMouseButtonEvent(cx, cy, 0, false, game, 1)
                    end)
                    pcall(function() obj.MouseButton1Click:Fire() end)
                    pcall(function() obj:Activate() end)
                    Tools.logInfo("Закрыл плашку телепорта", { category = "HOP", btn = obj.Name })
                    return
                end
            end
        end
    end)
end

function Tools._onTeleportFail(result)
    if not Tools.isEnabled() then return end
    local R = Enum.TeleportResult

    -- IsTeleporting = предыдущий телепорт ещё обрабатывается Roblox. НЕ стреляем
    -- новым (иначе "previous teleport is in processing" по кругу). Ждём, пока тот
    -- сам разрешится: успех убьёт VM, реальный отказ прилетит сюда же. Троттлинг
    -- в safeTeleport не даст спама; зависший TP получит шанс завершиться.
    if result == R.IsTeleporting then
        Tools.logWarning("Телепорт уже в процессе — жду разрешения, без ретрая", {
            category = "HOP", result = tostring(result),
        })
        return
    end

    local delay, retriable = 3, true
    if result == R.Flooded then
        delay = 15                                   -- рейт-лимит телепортов → ждём дольше
    elseif result == R.GameFull or result == R.GameNotFound
        or result == R.GameEnded or result == R.Failure then
        delay = 2                                     -- сервер полон/недоступен → берём ДРУГОЙ
    elseif result == R.Unauthorized then
        retriable = false                             -- фатально, не ретраим
    end

    Tools._dismissTeleportPrompt()

    if not retriable then
        Tools.logWarning("Телепорт: фатальный отказ, без ретрая",
            { category = "HOP", result = tostring(result) })
        return
    end

    Tools._tpFailRetries = (Tools._tpFailRetries or 0) + 1
    if Tools._tpFailRetries > TP_FAIL_MAX then
        Tools.logError("Телепорт: лимит авто-перезаходов исчерпан, жду планового хопа",
            { category = "HOP", retries = Tools._tpFailRetries })
        return
    end

    Tools.logWarning("Сервер полон/недоступен — перезаход на другой", {
        category = "HOP", result = tostring(result),
        attempt = Tools._tpFailRetries, wait_s = delay,
    })
    task.spawn(function()
        task.wait(delay)
        if Tools.isEnabled() and not _G.IsHopping then
            Tools.fastServerHop()   -- атомарный захват ДРУГОГО сервера (только что посещённый rpc исключит)
        end
    end)
end

function Tools.setup(opts)
    opts = opts or {}
    if opts.minPlayersPreferred then Tools.minPlayersPreferred = opts.minPlayersPreferred end
    if opts.maxPlayersAllowed   then Tools.maxPlayersAllowed   = opts.maxPlayersAllowed   end
    if opts.searchTimeout       then Tools.searchTimeout       = opts.searchTimeout       end
    if opts.teleportCooldown    then Tools.teleportCooldown    = opts.teleportCooldown    end
    if opts.minServerDwell      then Tools.minServerDwell      = opts.minServerDwell      end
    if opts.placeId             then Tools.placeId             = opts.placeId             end
    if opts.scriptUrl           then Tools.scriptUrl           = opts.scriptUrl           end
    Tools._startTick = tick()   -- момент захода на сервер, отсчёт dwell
    Tools._tpFailRetries = 0    -- новый сервер = новый VM, сбрасываем счётчик авто-перезаходов

    -- если телепорт провалился асинхронно — снимаем guard (иначе зависание в IsHopping)
    -- и, если сервер полон/недоступен, перезаходим на ДРУГОЙ (см. Tools._onTeleportFail).
    if not Tools._tpFailHooked then
        Tools._tpFailHooked = true
        pcall(function()
            TeleportService.TeleportInitFailed:Connect(function(plr, result, msg)
                if plr == player then
                    _G.IsHopping = false
                    Tools.logWarning("TeleportInitFailed — сбрасываю IsHopping", {
                        category = "HOP", result = tostring(result), msg = tostring(msg),
                    })
                    Tools._onTeleportFail(result)
                end
            end)
        end)
    end
    return Tools
end

-- ============================================================
-- SAFE TELEPORT: единый шлюз для всех телепортов.
-- Исключает конкурентные вызовы (несколько watchdog'ов + runBot
-- + xpcall дёргали Teleport одновременно → Roblox кикал/крашил)
-- и не даёт хопать чаще, чем раз в minServerDwell секунд.
-- ============================================================
function Tools.safeTeleport(reason, teleportFn, immediate)
    if _G.IsHopping then
        Tools.logDebug("safeTeleport: hop уже идёт, пропуск", { category = "HOP", reason = reason })
        return false
    end
    -- анти-IsTeleporting: не стартуем телепорт, пока с прошлого старта не прошло
    -- tpMinGap (Roblox держит "teleport in processing"). Спасает от вечного дедлока.
    local sinceLastTp = tick() - (Tools._lastTpFireAt or 0)
    if sinceLastTp < (Tools.tpMinGap or 30) then
        Tools.logDebug("safeTeleport: рано после прошлого TP, пропуск", {
            category = "HOP", reason = reason, since_s = math.floor(sinceLastTp),
        })
        return false
    end
    _G.IsHopping = true

    local elapsed = tick() - (Tools._startTick or tick())
    if not immediate and elapsed < Tools.minServerDwell then
        local wait = Tools.minServerDwell - elapsed
        Tools.logDebug("safeTeleport: добор dwell перед hop", {
            category = "HOP", reason = reason, wait_s = math.floor(wait),
        })
        task.wait(wait)
    end

    pcall(Tools._flushLogs)
    Tools._lastTpFireAt = tick()   -- момент старта телепорта (для троттлинга выше)
    local ok, err = pcall(teleportFn)
    if not ok then
        _G.IsHopping = false   -- телепорт не стартовал — разрешаем следующую попытку
        Tools.logError("safeTeleport: телепорт упал", {
            category = "HOP", reason = reason, error = tostring(err),
        })
    end
    return ok
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

    Tools.lastSentText = msg
    Tools.lastSentAt   = tick()
    Tools.bumpSession("messages")
    Tools.logInfo("Сообщение отправлено", {
        category    = "CHAT",
        message     = msg,
        length      = #msg,
        duration_ms = durationMs(t0),
    })
end

-- найти текстовый канал для SendAsync (RBXGeneral — основной публичный чат)
function Tools._getTextChannel()
    local ok, ch = pcall(function()
        local TCS   = game:GetService("TextChatService")
        local chans = TCS:WaitForChild("TextChannels", 5)
        if not chans then return nil end
        return chans:FindFirstChild("RBXGeneral")
            or chans:FindFirstChildWhichIsA("TextChannel")
    end)
    if ok then return ch end
    return nil
end

-- доля изменённых символов оригинал↔отфильтрованный (фильтр сохраняет длину, бьёт #/*)
local function _censoredRatio(orig, filtered)
    if not orig or not filtered then return 0 end
    if #orig ~= #filtered then return 1.0 end
    local diff = 0
    for i = 1, #orig do
        if orig:sub(i, i) ~= filtered:sub(i, i) then diff = diff + 1 end
    end
    return diff / math.max(#orig, 1)
end

-- Отправка через TextChannel:SendAsync — возвращает результат фильтрации НАПРЯМУЮ
-- (Status + отфильтрованный Text), не зависит от TextSource/колбэков, которые в этом
-- executor'е не отдают своё эхо. Возврат: result ("ok"/"censored"/"flood"/"blocked"/"error").
function Tools.sendChatAsync(msg)
    local t0 = tick()
    local ch = Tools._getTextChannel()
    if not ch then
        Tools.logWarning("SendAsync: канал не найден", { category = "CHAT" })
        return "error", nil
    end
    Tools.randomDelay(0.2, 0.6)
    local ok, msgObj = pcall(function() return ch:SendAsync(msg) end)
    if not ok or not msgObj then
        Tools.logWarning("SendAsync упал", { category = "CHAT", error = tostring(msgObj) })
        return "error", nil
    end

    Tools.lastSentText = msg
    Tools.lastSentAt   = tick()
    Tools.bumpSession("messages")

    -- Delta НЕ возвращает финальный статус своего сообщения: эхо своего текста в
    -- executor-контекст не приходит ничем (см. §4/§7), статус навсегда остаётся
    -- "Sending". Поэтому НЕ ждём его (раньше ждали 3с впустую на КАЖДОЙ рекламе с
    -- нулевой пользой). Реклама уходит независимо от статуса — классифицируем сразу
    -- по тому, что прилетело синхронно.
    local status   = msgObj.Status
    local filtered = msgObj.Text
    local result
    if status == Enum.TextChatMessageStatus.Success then
        result = (_censoredRatio(msg, filtered) > 0) and "censored" or "ok"
    elseif status == Enum.TextChatMessageStatus.Floodchecked then
        result = "flood"
    elseif status == Enum.TextChatMessageStatus.Sending then
        result = "sent"      -- норма в Delta: реклама отправлена, квитанция недоступна
    else
        result = "blocked"   -- терминальная ошибка вернулась синхронно
    end
    Tools.filterStats[result] = (Tools.filterStats[result] or 0) + 1

    Tools.logInfo("Реклама отправлена (SendAsync)", {
        category    = "CHAT",
        message     = msg,
        result      = result,
        status      = tostring(status),
        filtered    = (result == "censored") and filtered or nil,
        stats       = Tools.filterStats,
        duration_ms = durationMs(t0),
    })
    return result, filtered
end

-- ============================================================
-- CHAT LISTENER
-- ============================================================
Tools.chatMessageBuffer     = {}
Tools.chatBufferMaxSize     = 50
Tools.chatListenerConnected = false

-- ОХВАТ: уникальные UserId игроков, которые РЕАЛЬНО писали в чат при нас за этот
-- заход. Кто пишет — тот точно видит чат (прошёл age-check 2026, совместимая
-- возрастная группа). Это «пол» охвата. Сбрасывается сам на новом сервере
-- (телепорт = новый Lua VM), поэтому всегда считает только текущий заход.
Tools.visitChatters = {}

-- надёжный канал СВОЕГО эха: TextChatService.OnIncomingMessage на отправителе
-- срабатывает дважды (Sending → финал с отфильтрованным текстом). MessageReceived
-- свои сообщения от VirtualInputManager не отдаёт (self_in_buffer=0), отсюда фикс.
Tools._selfEchoes      = {}
Tools._selfEchoMax     = 20
Tools._onIncomingHooked = false

-- статистика фильтрации за сессию (видно в логах: сколько ушло в блок/прошло)
Tools.filterStats = { ok = 0, censored = 0, flood = 0, blocked = 0, sent = 0, no_echo = 0 }

-- единая точка приёма сообщения в буфер.
-- at = tick() (монотонный, для точного окна "после отправки"),
-- timestamp = os.time() (для совместимости). userId/isSelf — best-effort,
-- НЕ основной канал идентификации своих (см. checkAndDeactivateIfFiltered: матч по тексту).
function Tools._pushChatMessage(text, sender, userId)
    text   = text or ""
    sender = sender or "Unknown"
    local isSelf = false
    if userId and player and userId == player.UserId then isSelf = true end
    if not isSelf and player and sender == player.Name then isSelf = true end
    -- чужой игрок что-то написал → он точно видит чат, засчитываем в охват
    if not isSelf and userId and userId > 0 then
        Tools.visitChatters[userId] = true
    end
    -- ДИАГНОСТИКА цензуры (v3.21): своё эхо в Delta не видно, но ЧУЖИЕ сообщения видны.
    -- Логируем чужие сообщения, похожие на рекламу сайта или зацензуренные (###) —
    -- покажет, режет ли фильтр ссылки в чат вообще (для всех), или пропускает.
    if not isSelf and text ~= "" then
        local low = string.lower(text)
        if string.find(text, "###", 1, true)
           or string.find(low, "rblx", 1, true) or string.find(low, "adoptme", 1, true)
           or string.find(low, " dot ", 1, true) or string.find(low, "http", 1, true)
           or string.find(low, "discord", 1, true) or string.find(low, ".pw", 1, true)
           or string.find(low, " pw", 1, true) or string.find(low, ".gg", 1, true) then
            pcall(function()
                Tools.logInfo("Чужое сообщение (диагностика фильтра)", {
                    category = "FILTER_OBS", text = text, sender = tostring(sender),
                })
            end)
        end
    end
    table.insert(Tools.chatMessageBuffer, 1, {
        text = text, sender = sender, userId = userId or 0,
        isSelf = isSelf, at = tick(), timestamp = os.time(),
    })
    while #Tools.chatMessageBuffer > Tools.chatBufferMaxSize do
        table.remove(Tools.chatMessageBuffer)
    end
end

function Tools.connectChatListener()
    if Tools.chatListenerConnected then return true end
    local methods = {}

    -- TextChatService (современный чат). Слушаем И сервис целиком, И каждый канал —
    -- разные игры/executor'ы доставляют echo по-разному, ловим максимально широко.
    pcall(function()
        local TextChatService = game:GetService("TextChatService")

        -- сервис-уровневый MessageReceived: ловит сообщения со всех каналов
        pcall(function()
            TextChatService.MessageReceived:Connect(function(m)
                local uid
                if m.TextSource then uid = m.TextSource.UserId end
                Tools._pushChatMessage(m.Text, nil, uid)
            end)
            table.insert(methods, "TCS.MessageReceived")
        end)

        local channels = TextChatService:WaitForChild("TextChannels", 5)
        if channels then
            local function hookChannel(ch)
                if not ch:IsA("TextChannel") then return end
                pcall(function()
                    ch.MessageReceived:Connect(function(m)
                        local uid, sender
                        if m.TextSource then
                            uid = m.TextSource.UserId
                            local p = Players:GetPlayerByUserId(uid)
                            if p then sender = p.Name end
                        end
                        Tools._pushChatMessage(m.Text, sender, uid)
                    end)
                end)
            end
            for _, ch in ipairs(channels:GetChildren()) do hookChannel(ch) end
            channels.ChildAdded:Connect(hookChannel) -- каналы создаются не сразу
            table.insert(methods, "TextChannels")
        end
    end)

    -- OnIncomingMessage: единственный надёжный канал своего эха (вкл. отфильтрованный текст).
    -- Колбэк один на сервис — сохраняем предыдущий и проксируем, чтобы не сломать игровой чат.
    pcall(function()
        if Tools._onIncomingHooked then return end
        local TCS = game:GetService("TextChatService")
        local prev = TCS.OnIncomingMessage
        TCS.OnIncomingMessage = function(message)
            pcall(function()
                local ts = message.TextSource
                if ts and player and ts.UserId == player.UserId then
                    -- финал (не Sending) = серверная отфильтрованная версия нашего текста
                    if message.Status ~= Enum.TextChatMessageStatus.Sending then
                        table.insert(Tools._selfEchoes, 1, {
                            text   = message.Text,
                            at     = tick(),
                            status = tostring(message.Status),
                        })
                        while #Tools._selfEchoes > Tools._selfEchoMax do
                            table.remove(Tools._selfEchoes)
                        end
                    end
                end
            end)
            if prev then return prev(message) end
            return nil
        end
        Tools._onIncomingHooked = true
        table.insert(methods, "OnIncomingMessage")
    end)

    -- Legacy chat (старые игры / запасной путь)
    pcall(function()
        local RS = game:GetService("ReplicatedStorage")
        local ev = RS:FindFirstChild("DefaultChatSystemChatEvents")
        if ev then
            local on = ev:FindFirstChild("OnMessageDoneFiltering")
            if on then
                on.OnClientEvent:Connect(function(d)
                    Tools._pushChatMessage(d.Message or d.FilteredMessage, d.FromSpeaker, nil)
                end)
                table.insert(methods, "Legacy")
            end
        end
    end)

    Tools.chatListenerConnected = #methods > 0
    if Tools.chatListenerConnected then
        Tools.logInfo("Chat listener подключён", {
            category = "CHAT_LISTENER", methods = table.concat(methods, ","),
        })
    else
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

-- только наши собственные сообщения из чата (sender == имя текущего игрока).
-- нужно, чтобы фильтр-чек не реагировал на чужой зацензуренный текст.
function Tools.getMyRecentChatMessages(count)
    count = count or 5
    if not Tools.chatListenerConnected then Tools.connectChatListener() end
    local myName = (player and player.Name) or ""
    local out = {}
    for i = 1, #Tools.chatMessageBuffer do
        local m = Tools.chatMessageBuffer[i]
        -- isSelf метится по UserId при захвате; sender-имя как запасной матч
        if m.isSelf or (myName ~= "" and m.sender == myName) then
            table.insert(out, m.text)
            if #out >= count then break end
        end
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

-- является ли `cand` зацензуренной версией `orig`.
-- Roblox-фильтр заменяет проблемные символы на '#' (иногда '*'), СОХРАНЯЯ длину строки
-- и пробелы. Поэтому censored-версия = та же длина, на немаскированных позициях те же
-- символы, и есть хотя бы один '#'/'*'. Сравнение не зависит от TextSource/имени.
local function isCensoredVersionOf(cand, orig)
    if not cand or not orig then return false end
    if #orig < 4 or #cand ~= #orig then return false end
    local masks = 0
    for i = 1, #orig do
        local c = cand:sub(i, i)
        if c == "#" or c == "*" then
            masks = masks + 1
        elseif c ~= orig:sub(i, i) then
            return false -- немаскированный символ не совпал → это другое сообщение
        end
    end
    return masks > 0
end

-- кулдаун (в минутах) для объявления, чьё сообщение зацензурил чат-фильтр.
-- НЕ деактивируем перманентно — иначе любой ложный срабат выжигает пул навсегда.
Tools.filteredCooldownMinutes = 360

-- Источник истины — Tools._selfEchoes (наполняется из OnIncomingMessage финальной,
-- отфильтрованной версией нашего текста). Сравнение по содержимому: exact = прошло,
-- censored (та же длина, есть #/*) = зацензурено. Возврат true = фильтр сработал.
function Tools.checkAndDeactivateIfFiltered(adMessageId, waitTime, sentText)
    waitTime = waitTime or 3
    local t0 = tick()
    local windowStart = (Tools.lastSentAt or t0) - 1.0 -- echo мог прийти чуть раньше входа
    sentText = sentText or Tools.lastSentText
    task.wait(waitTime)

    if not sentText or sentText == "" then
        Tools.filterStats.no_echo = Tools.filterStats.no_echo + 1
        Tools.logDebug("Нет отправленного текста — пропуск фильтр-чека",
            { category = "FILTER", message_id = adMessageId })
        return false
    end

    -- ищем финальное эхо нашего текста среди self-echoes после момента отправки
    local exactHit, censoredHit, badMsg, badStatus = false, false, nil, nil
    local echoSeen = 0
    for _, e in ipairs(Tools._selfEchoes) do
        if (e.at or 0) >= windowStart then
            echoSeen = echoSeen + 1
            if e.text == sentText then
                exactHit = true
            elseif isCensoredVersionOf(e.text, sentText) then
                censoredHit, badMsg, badStatus = true, e.text, e.status
            end
        end
    end

    if censoredHit then
        Tools.filterStats.censored = Tools.filterStats.censored + 1
        Tools.logWarning("Своё сообщение зацензурено — длинный cooldown", {
            category      = "FILTER",
            result        = "censored",
            message_id    = adMessageId,
            sent_text     = sentText,
            filtered_text = badMsg,
            status        = badStatus,
            cooldown_min  = Tools.filteredCooldownMinutes,
            stats         = Tools.filterStats,
            duration_ms   = durationMs(t0),
        })
        if adMessageId then
            Tools.markAdMessageUsed(adMessageId, Tools.filteredCooldownMinutes)
        end
        return true
    end

    if exactHit then
        Tools.filterStats.ok = Tools.filterStats.ok + 1
    else
        -- эхо не пришло — не делаем выводов (консервативно: не фильтр)
        Tools.filterStats.no_echo = Tools.filterStats.no_echo + 1
    end
    Tools.logInfo("Фильтр-чек: сообщение прошло", {
        category    = "FILTER",
        result      = exactHit and "ok" or "no_echo",
        message_id  = adMessageId,
        echo_found  = exactHit,
        echo_seen   = echoSeen,
        stats       = Tools.filterStats,
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

                    if not scriptQueued and queueFunc then
                        pcall(function()
                            queueFunc('loadstring(game:HttpGet("'
                                .. Tools.scriptUrl .. '?t=' .. tick() .. '"))()')
                            scriptQueued = true
                        end)
                    end
                    local tpOk = Tools.safeTeleport("server-hop", function()
                        TeleportService:TeleportToPlaceInstance(Tools.placeId, sid, player)
                    end)

                    if tpOk then
                        Tools.logInfo("Телепорт выполнен", {
                            category    = "HOP",
                            server_id   = sid,
                            duration_ms = durationMs(hopStart),
                        })
                        return true
                    else
                        Tools.logWarning("Ошибка телепорта, ищу дальше", {
                            category  = "HOP",
                            server_id = sid,
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
