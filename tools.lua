

local Players = game:GetService("Players")
local VirtualInputManager = game:GetService("VirtualInputManager")
local GuiService = game:GetService("GuiService")
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")


local queueFunc = queueonteleport
local scriptQueued = false
local httprequest = http_request or http.request or request or (syn and syn.request)

local player = Players.LocalPlayer
local playerGui = player:FindFirstChild("PlayerGui")

local Tools = {
    apiUrl = "",
    apiKey = "",
    minPlayersPreferred = 5,
    maxPlayersAllowed = 15,
    searchTimeout = 60,
    teleportCooldown = 15,
    placeId = 920587237,
    scriptUrl = "",
    enabled = true,  
    gui = nil,
    botState = {
        running = false,
        settingsVisible = false
    }
}

local function shuffleArray(arr)
    local n = #arr
    for i = n, 2, -1 do
        local j = math.random(1, i)
        arr[i], arr[j] = arr[j], arr[i]
    end
    return arr
end

-- Создание GUI с настройками бота
function Tools.createSettingsGUI(onStartCallback)
    local Players = game:GetService("Players")
    local player = Players.LocalPlayer
    local playerGui = player:WaitForChild("PlayerGui")

    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = "BotSettingsGUI"
    screenGui.ResetOnSpawn = false
    screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

    local settingsButton = Instance.new("TextButton")
    settingsButton.Name = "SettingsButton"
    settingsButton.Size = UDim2.new(0, 120, 0, 40)
    settingsButton.Position = UDim2.new(0, 10, 1, -50)
    settingsButton.BackgroundColor3 = Color3.fromRGB(50, 50, 50)
    settingsButton.Text = "⚙️ Настройки"
    settingsButton.TextColor3 = Color3.fromRGB(255, 255, 255)
    settingsButton.TextSize = 14
    settingsButton.Font = Enum.Font.SourceSansBold
    settingsButton.Parent = screenGui

    local buttonCorner = Instance.new("UICorner")
    buttonCorner.CornerRadius = UDim.new(0, 8)
    buttonCorner.Parent = settingsButton

    local settingsFrame = Instance.new("Frame")
    settingsFrame.Name = "SettingsFrame"
    settingsFrame.Size = UDim2.new(0, 350, 0, 300)
    settingsFrame.Position = UDim2.new(0.5, -175, 0.5, -150)
    settingsFrame.BackgroundColor3 = Color3.fromRGB(35, 35, 35)
    settingsFrame.BorderSizePixel = 2
    settingsFrame.BorderColor3 = Color3.fromRGB(255, 255, 255)
    settingsFrame.Visible = false
    settingsFrame.Parent = screenGui

    local frameCorner = Instance.new("UICorner")
    frameCorner.CornerRadius = UDim.new(0, 8)
    frameCorner.Parent = settingsFrame

    local title = Instance.new("TextLabel")
    title.Name = "Title"
    title.Size = UDim2.new(1, -20, 0, 30)
    title.Position = UDim2.new(0, 10, 0, 10)
    title.BackgroundTransparency = 1
    title.Text = "🤖 Настройки бота"
    title.TextColor3 = Color3.fromRGB(255, 255, 255)
    title.TextSize = 18
    title.Font = Enum.Font.SourceSansBold
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Parent = settingsFrame

    local apiLabel = Instance.new("TextLabel")
    apiLabel.Name = "ApiLabel"
    apiLabel.Size = UDim2.new(1, -20, 0, 20)
    apiLabel.Position = UDim2.new(0, 10, 0, 50)
    apiLabel.BackgroundTransparency = 1
    apiLabel.Text = "🔑 API Ключ:"
    apiLabel.TextColor3 = Color3.fromRGB(220, 220, 220)
    apiLabel.TextSize = 14
    apiLabel.Font = Enum.Font.SourceSansBold
    apiLabel.TextXAlignment = Enum.TextXAlignment.Left
    apiLabel.Parent = settingsFrame

    local apiInput = Instance.new("TextBox")
    apiInput.Name = "ApiInput"
    apiInput.Size = UDim2.new(1, -20, 0, 40)
    apiInput.Position = UDim2.new(0, 10, 0, 75)
    apiInput.PlaceholderText = "Введите ваш API ключ"
    apiInput.Text = Tools.apiKey
    apiInput.TextColor3 = Color3.new(1, 1, 1)
    apiInput.BackgroundColor3 = Color3.fromRGB(50, 50, 50)
    apiInput.BorderSizePixel = 1
    apiInput.BorderColor3 = Color3.fromRGB(70, 70, 70)
    apiInput.Font = Enum.Font.SourceSans
    apiInput.TextSize = 14
    apiInput.ClearTextOnFocus = false
    apiInput.TextXAlignment = Enum.TextXAlignment.Left
    apiInput.Parent = settingsFrame

    local inputCorner = Instance.new("UICorner")
    inputCorner.CornerRadius = UDim.new(0, 4)
    inputCorner.Parent = apiInput

    local inputPadding = Instance.new("UIPadding")
    inputPadding.PaddingLeft = UDim.new(0, 8)
    inputPadding.Parent = apiInput

    -- Настройка минимального количества игроков
    local minPlayersLabel = Instance.new("TextLabel")
    minPlayersLabel.Name = "MinPlayersLabel"
    minPlayersLabel.Size = UDim2.new(1, -20, 0, 20)
    minPlayersLabel.Position = UDim2.new(0, 10, 0, 125)
    minPlayersLabel.BackgroundTransparency = 1
    minPlayersLabel.Text = "👥 Минимум игроков на сервере:"
    minPlayersLabel.TextColor3 = Color3.fromRGB(220, 220, 220)
    minPlayersLabel.TextSize = 14
    minPlayersLabel.Font = Enum.Font.SourceSansBold
    minPlayersLabel.TextXAlignment = Enum.TextXAlignment.Left
    minPlayersLabel.Parent = settingsFrame

    local minPlayersInput = Instance.new("TextBox")
    minPlayersInput.Name = "MinPlayersInput"
    minPlayersInput.Size = UDim2.new(1, -20, 0, 35)
    minPlayersInput.Position = UDim2.new(0, 10, 0, 150)
    minPlayersInput.PlaceholderText = "5"
    minPlayersInput.Text = tostring(Tools.minPlayersPreferred or 5)
    minPlayersInput.TextColor3 = Color3.new(1, 1, 1)
    minPlayersInput.BackgroundColor3 = Color3.fromRGB(50, 50, 50)
    minPlayersInput.BorderSizePixel = 1
    minPlayersInput.BorderColor3 = Color3.fromRGB(70, 70, 70)
    minPlayersInput.Font = Enum.Font.SourceSans
    minPlayersInput.TextSize = 14
    minPlayersInput.ClearTextOnFocus = false
    minPlayersInput.TextXAlignment = Enum.TextXAlignment.Left
    minPlayersInput.Parent = settingsFrame

    local minPlayersCorner = Instance.new("UICorner")
    minPlayersCorner.CornerRadius = UDim.new(0, 4)
    minPlayersCorner.Parent = minPlayersInput

    local minPlayersPadding = Instance.new("UIPadding")
    minPlayersPadding.PaddingLeft = UDim.new(0, 8)
    minPlayersPadding.Parent = minPlayersInput

    local startButton = Instance.new("TextButton")
    startButton.Name = "StartButton"
    startButton.Size = UDim2.new(1, -20, 0, 45)
    startButton.Position = UDim2.new(0, 10, 0, 200)
    startButton.Text = "▶️ Старт"
    startButton.BackgroundColor3 = Color3.fromRGB(0, 170, 0)
    startButton.BorderSizePixel = 0
    startButton.TextColor3 = Color3.new(1, 1, 1)
    startButton.Font = Enum.Font.SourceSansBold
    startButton.TextSize = 16
    startButton.Parent = settingsFrame

    local startCorner = Instance.new("UICorner")
    startCorner.CornerRadius = UDim.new(0, 6)
    startCorner.Parent = startButton

    local statusLabel = Instance.new("TextLabel")
    statusLabel.Name = "StatusLabel"
    statusLabel.Size = UDim2.new(1, -20, 0, 20)
    statusLabel.Position = UDim2.new(0, 10, 0, 255)
    statusLabel.BackgroundTransparency = 1
    statusLabel.Text = ""
    statusLabel.TextColor3 = Color3.fromRGB(100, 200, 100)
    statusLabel.TextSize = 12
    statusLabel.Font = Enum.Font.SourceSans
    statusLabel.TextXAlignment = Enum.TextXAlignment.Center
    statusLabel.Parent = settingsFrame

    apiInput:GetPropertyChangedSignal("Text"):Connect(function()
        Tools.apiKey = apiInput.Text
    end)

    minPlayersInput:GetPropertyChangedSignal("Text"):Connect(function()
        local num = tonumber(minPlayersInput.Text)
        if num and num >= 1 and num <= 100 then
            Tools.minPlayersPreferred = num
        end
    end)

    settingsButton.MouseButton1Click:Connect(function()
        Tools.botState.running = false
        Tools.botState.settingsVisible = not Tools.botState.settingsVisible
        settingsFrame.Visible = Tools.botState.settingsVisible
        
        if Tools.botState.settingsVisible then
            settingsButton.Text = "❌ Закрыть"
            settingsButton.BackgroundColor3 = Color3.fromRGB(170, 0, 0)
        else
            settingsButton.Text = "⚙️ Настройки"
            settingsButton.BackgroundColor3 = Color3.fromRGB(50, 50, 50)
        end
    end)

    startButton.MouseButton1Click:Connect(function()
        if Tools.apiKey == "" then
            statusLabel.Text = "⚠ Введите API ключ!"
            statusLabel.TextColor3 = Color3.fromRGB(200, 150, 100)
            task.delay(2, function()
                statusLabel.Text = ""
            end)
            return
        end

        -- Валидация минимального количества игроков
        local minPlayers = tonumber(minPlayersInput.Text)
        if not minPlayers or minPlayers < 1 or minPlayers > 100 then
            statusLabel.Text = "⚠ Введите число от 1 до 100!"
            statusLabel.TextColor3 = Color3.fromRGB(200, 150, 100)
            task.delay(2, function()
                statusLabel.Text = ""
            end)
            return
        end

        Tools.minPlayersPreferred = minPlayers

        local write = writefile or write_file or (syn and syn.write_file)
        if write and type(write) == "function" then
            pcall(function()
                write("password.txt", Tools.apiKey)
            end)
        end

        -- Сохраняем конфигурацию
        local config = {
            minPlayersPreferred = Tools.minPlayersPreferred
        }
        Tools.saveConfig(config)

        Tools.botState.running = true
        Tools.botState.settingsVisible = false
        settingsFrame.Visible = false
        settingsButton.Text = "⚙️ Настройки"
        settingsButton.BackgroundColor3 = Color3.fromRGB(50, 50, 50)

        statusLabel.Text = "✓ Запуск..."
        statusLabel.TextColor3 = Color3.fromRGB(100, 200, 100)

        if onStartCallback then
            task.spawn(function()
                onStartCallback()
            end)
        end
    end)

    screenGui.Parent = playerGui
    Tools.gui = screenGui

    return screenGui
end

-- Получить состояние бота
function Tools.getBotState()
    return Tools.botState
end

-- Загрузить сохраненный API ключ
function Tools.loadSavedApiKey()
    local checkfile = isfile or isfile_custom or (syn and syn.is_file)
    local read = readfile or read_file or (syn and syn.read_file)

    if checkfile and read and type(checkfile) == "function" and type(read) == "function" then
        local success, fileExists = pcall(function()
            return checkfile("password.txt")
        end)

        if success and fileExists then
            local readSuccess, savedKey = pcall(function()
                return read("password.txt")
            end)

            if readSuccess and savedKey and savedKey ~= "" then
                Tools.apiKey = savedKey
                return savedKey
            end
        end
    end

    return nil
end

-- Сохранить конфигурацию
function Tools.saveConfig(config)
    local write = writefile or write_file or (syn and syn.write_file)
    if not write or type(write) ~= "function" then
        return false
    end

    local HttpService = game:GetService("HttpService")
    local success = pcall(function()
        local jsonConfig = HttpService:JSONEncode(config)
        write("bot_config.json", jsonConfig)
    end)

    return success
end

-- Загрузить конфигурацию
function Tools.loadConfig()
    local checkfile = isfile or isfile_custom or (syn and syn.is_file)
    local read = readfile or read_file or (syn and syn.read_file)

    if checkfile and read and type(checkfile) == "function" and type(read) == "function" then
        local success, fileExists = pcall(function()
            return checkfile("bot_config.json")
        end)

        if success and fileExists then
            local readSuccess, configJson = pcall(function()
                return read("bot_config.json")
            end)

            if readSuccess and configJson and configJson ~= "" then
                local HttpService = game:GetService("HttpService")
                local decodeSuccess, config = pcall(function()
                    return HttpService:JSONDecode(configJson)
                end)

                if decodeSuccess and config then
                    return config
                end
            end
        end
    end

    return nil
end

-- Проверка, включен ли бот
function Tools.isEnabled()
    return Tools.enabled
end

-- Инициализация модуля с API параметрами
function Tools.setup(apiUrl, apiKey, minPlayersPreferred, maxPlayersAllowed, searchTimeout, teleportCooldown, placeId, scriptUrl, Auth)
    if apiUrl then Tools.apiUrl = apiUrl end
    if apiKey then Tools.apiKey = apiKey end
    if minPlayersPreferred then Tools.minPlayersPreferred = minPlayersPreferred end
    if maxPlayersAllowed then Tools.maxPlayersAllowed = maxPlayersAllowed end
    if searchTimeout then Tools.searchTimeout = searchTimeout end
    if teleportCooldown then Tools.teleportCooldown = teleportCooldown end
    if placeId then Tools.placeId = placeId end
    if scriptUrl then Tools.scriptUrl = scriptUrl end

    return Tools
end

-- Ожидание появления кнопки PlayButton (максимум 60 секунд)
function Tools.waitForPlayButton(timeout)
    timeout = timeout or 60
    local startTime = tick()

    while tick() - startTime < timeout do
        if Tools.isPlayButtonVisible() then
            return true
        end
        task.wait(0.5)
    end

    return false
end

-- Проверка видимости кнопки PlayButton
function Tools.isPlayButtonVisible()
    local newsApp = playerGui and playerGui:FindFirstChild("NewsApp")

    if not newsApp or newsApp.Enabled == false then
        return false
    end

    local enclosingFrame = newsApp:FindFirstChild("EnclosingFrame")
    local mainFrame = enclosingFrame and enclosingFrame:FindFirstChild("MainFrame")
    local buttons = mainFrame and mainFrame:FindFirstChild("Buttons")
    local playButton = buttons and buttons:FindFirstChild("PlayButton")

    return playButton ~= nil
end


function Tools.randomDelay(min, max)
    task.wait(min + math.random() * (max - min))
end

function Tools.getTypeDelay(char, prevChar)
    local baseDelay = 0.15 + math.random() * 0.15

    if prevChar == " " then
        baseDelay = baseDelay + math.random() * 0.1
    end

    if char:match("[A-ZА-Я]") then
        baseDelay = baseDelay + 0.02
    end

    if char:match("[%d%p]") then
        baseDelay = baseDelay + 0.03
    end

    return baseDelay
end

-- Клик по кнопке PlayButton
function Tools.clickPlayButton()
    local newsApp = playerGui and playerGui:FindFirstChild("NewsApp")
    if not newsApp or newsApp.Enabled == false then
        return false
    end

    local enclosingFrame = newsApp:FindFirstChild("EnclosingFrame")
    local mainFrame = enclosingFrame and enclosingFrame:FindFirstChild("MainFrame")
    local buttons = mainFrame and mainFrame:FindFirstChild("Buttons")
    local playButton = buttons and buttons:FindFirstChild("PlayButton")

    if not playButton then
        return false
    end

    local absolutePos = playButton.AbsolutePosition
    local absoluteSize = playButton.AbsoluteSize
    local guiInset = GuiService:GetGuiInset()

    local centerX = absolutePos.X + absoluteSize.X / 2
    local centerY = absolutePos.Y + absoluteSize.Y / 2 + guiInset.Y

    VirtualInputManager:SendMouseButtonEvent(centerX, centerY, 0, true, game, 1)
    task.wait(0.05)
    VirtualInputManager:SendMouseButtonEvent(centerX, centerY, 0, false, game, 1)

    return true
end

-- Проверка наличия кнопки Adoption Island
function Tools.isAdoptionIslandButtonVisible()
    local dialogApp = playerGui and playerGui:FindFirstChild("DialogApp")
    if not dialogApp then
        return false
    end

    local dialog = dialogApp:FindFirstChild("Dialog")
    local spawnChooser = dialog and dialog:FindFirstChild("SpawnChooserDialog")

    -- Проверяем, что окно SpawnChooser видимо (аналогично newsApp.Enabled для Play)
    if not spawnChooser or not spawnChooser.Visible then
        return false
    end

    local upperCard = spawnChooser:FindFirstChild("UpperCardContainer")
    local choicesContent = upperCard and upperCard:FindFirstChild("ChoicesContent")
    local choices = choicesContent and choicesContent:FindFirstChild("Choices")
    local adoptionIsland = choices and choices:FindFirstChild("Adoption Island")
    local button = adoptionIsland and adoptionIsland:FindFirstChild("Button")

    return button ~= nil and button.Visible
end

-- Ожидание появления кнопки Adoption Island
function Tools.waitForAdoptionIslandButton(timeout)
    timeout = timeout or 30
    local startTime = tick()

    while tick() - startTime < timeout do
        if Tools.isAdoptionIslandButtonVisible() then
            return true
        end
        task.wait(0.5)
    end

    return false
end

-- Клик по кнопке Adoption Island
function Tools.clickAdoptionIslandButton()
    local dialogApp = playerGui and playerGui:FindFirstChild("DialogApp")
    if not dialogApp then
        return false, "DialogApp не найден"
    end

    local dialog = dialogApp:FindFirstChild("Dialog")
    local spawnChooser = dialog and dialog:FindFirstChild("SpawnChooserDialog")

    -- Проверяем, что окно SpawnChooser видимо
    if not spawnChooser or not spawnChooser.Visible then
        return false, "Окно выбора локации не открыто"
    end

    local upperCard = spawnChooser:FindFirstChild("UpperCardContainer")
    local choicesContent = upperCard and upperCard:FindFirstChild("ChoicesContent")
    local choices = choicesContent and choicesContent:FindFirstChild("Choices")
    local adoptionIsland = choices and choices:FindFirstChild("Adoption Island")
    local button = adoptionIsland and adoptionIsland:FindFirstChild("Button")

    if not button or not button.Visible then
        return false, "Кнопка Adoption Island не найдена или не видима"
    end

    -- Кликаем по центру кнопки
    local absolutePos = button.AbsolutePosition
    local absoluteSize = button.AbsoluteSize
    local guiInset = GuiService:GetGuiInset()

    local centerX = absolutePos.X + absoluteSize.X / 2
    local centerY = absolutePos.Y + absoluteSize.Y / 2 + guiInset.Y

    VirtualInputManager:SendMouseButtonEvent(centerX, centerY, 0, true, game, 1)
    task.wait(0.05)
    VirtualInputManager:SendMouseButtonEvent(centerX, centerY, 0, false, game, 1)

    return true, "Клик по кнопке Adoption Island выполнен"
end


function Tools.sendChat(msg)
    Tools.randomDelay(0.2, 0.5)

    VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.Slash, false, game)
    Tools.randomDelay(0.03, 0.08)
    VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.Slash, false, game)

    Tools.randomDelay(0.2, 0.4)

    local prevChar = ""
    for i = 1, #msg do
        local char = msg:sub(i, i)
        VirtualInputManager:SendTextInputCharacterEvent(char, game)
        task.wait(Tools.getTypeDelay(char, prevChar))
        prevChar = char
    end

    Tools.randomDelay(0.1, 0.3)

    VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.Return, false, game)
    Tools.randomDelay(0.03, 0.07)
    VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.Return, false, game)
    Tools.logInfo("Сообщение отправлено в чат", {category = "CHAT", message = msg})

end


function Tools.sendMessageAPI(message)
    if not httprequest then
        warn("HTTP request function not available")
        return false
    end

    -- Добавляем bot_id (username игрока) для идентификации в админке
    local botId = player and player.Name or "unknown"
    local url = Tools.apiUrl .. "/log?level=INFO&message=" .. HttpService:UrlEncode(message) .. "&bot_id=" .. HttpService:UrlEncode(botId)

    local success, result = pcall(function()
        return httprequest({
            Url = url,
            Method = "POST",
            Headers = {
                ["Authorization"] = "Bearer " .. Tools.apiKey,
                ["Content-Type"] = "application/json"
            }
        })
    end)

    if success and result.StatusCode == 200 then
        print("✓ Сообщение отправлено через API")
        return true
    else
        warn("✗ Ошибка отправки через API:", result and result.StatusCode or "unknown")
        return false
    end
end


-- ============================================
-- ФУНКЦИИ СТРУКТУРИРОВАННОГО ЛОГИРОВАНИЯ
-- ============================================

-- Отправить структурированный лог на сервер
-- level: DEBUG, INFO, WARNING, ERROR, CRITICAL
-- message: текст сообщения
-- context: таблица с дополнительными данными (опционально)
function Tools.sendLog(level, message, context)
    if not httprequest then
        warn("[LOG] HTTP функция недоступна")
        return false
    end

    level = level or "INFO"
    local botId = player and player.Name or "unknown"

    -- Формируем URL с query параметрами
    local url = Tools.apiUrl .. "/log?level=" .. HttpService:UrlEncode(level)
        .. "&message=" .. HttpService:UrlEncode(message)
        .. "&bot_id=" .. HttpService:UrlEncode(botId)

    -- Подготавливаем тело запроса с контекстом
    local body = nil
    if context and type(context) == "table" then
        local ok, jsonBody = pcall(function()
            return HttpService:JSONEncode(context)
        end)
        if ok then
            body = jsonBody
        end
    end

    local success, result = pcall(function()
        return httprequest({
            Url = url,
            Method = "POST",
            Headers = {
                ["Authorization"] = "Bearer " .. Tools.apiKey,
                ["Content-Type"] = "application/json"
            },
            Body = body
        })
    end)

    if success and result.StatusCode == 200 then
        return true
    else
        -- Fallback на старый метод если новый не работает
        Tools.sendMessageAPI("[" .. level .. "] " .. message)
        return false
    end
end

-- Хелперы для разных уровней логирования
function Tools.logDebug(message, context)
    return Tools.sendLog("DEBUG", message, context)
end

function Tools.logInfo(message, context)
    return Tools.sendLog("INFO", message, context)
end

function Tools.logWarning(message, context)
    return Tools.sendLog("WARNING", message, context)
end

function Tools.logError(message, context)
    return Tools.sendLog("ERROR", message, context)
end

function Tools.logCritical(message, context)
    return Tools.sendLog("CRITICAL", message, context)
end


-- ============================================
-- ЗАГРУЗКА КОНФИГУРАЦИИ С СЕРВЕРА
-- ============================================

-- Кэш конфигурации
Tools.remoteConfig = nil
Tools.remoteConfigTimestamp = 0
Tools.remoteConfigCacheTTL = 300 -- 5 минут

-- Загрузить конфигурацию с сервера
function Tools.loadRemoteConfig(forceRefresh)
    if not httprequest then
        warn("[CONFIG] HTTP функция недоступна")
        return nil
    end

    -- Проверяем кэш
    local now = os.time()
    if not forceRefresh and Tools.remoteConfig and (now - Tools.remoteConfigTimestamp) < Tools.remoteConfigCacheTTL then
        return Tools.remoteConfig
    end

    local botId = player and player.Name or "unknown"
    local url = Tools.apiUrl .. "/bot/config?bot_id=" .. HttpService:UrlEncode(botId)

    local success, response = pcall(function()
        return httprequest({
            Url = url,
            Method = "GET",
            Headers = {
                ["Authorization"] = "Bearer " .. Tools.apiKey,
                ["Content-Type"] = "application/json"
            }
        })
    end)

    if success and response.StatusCode == 200 then
        local ok, data = pcall(function()
            return HttpService:JSONDecode(response.Body)
        end)

        if ok and data.success and data.config then
            Tools.remoteConfig = data.config
            Tools.remoteConfigTimestamp = now
            Tools.logInfo("Конфигурация загружена с сервера", {keys = #data.config})
            return data.config
        end
    end

    Tools.logWarning("Не удалось загрузить конфигурацию с сервера")
    return nil
end

-- Получить значение из удалённой конфигурации
function Tools.getRemoteConfigValue(key, defaultValue)
    local config = Tools.loadRemoteConfig()
    if config and config[key] ~= nil then
        return config[key]
    end
    return defaultValue
end


-- Получить список посещенных серверов
function Tools.getVisitedServers(hours)
    hours = hours or 24
    if not httprequest then
        warn("[SERVERS] HTTP функция недоступна!")
        return {}
    end

    local success, response = pcall(function()
        return httprequest({
            Url = Tools.apiUrl .. "/servers/visited?hours=" .. hours,
            Method = "GET",
            Headers = {
                ["Authorization"] = "Bearer " .. Tools.apiKey,
                ["Content-Type"] = "application/json"
            }
        })
    end)

    if success and response.StatusCode == 200 then
        local data = HttpService:JSONDecode(response.Body)
        if data.success then
            Tools.logDebug("Загружено посещенных серверов", {category = "SERVERS", count = data.count})
            return data.servers
        end
    else
        Tools.logWarning("Ошибка загрузки серверов", {category = "SERVERS", status = response and response.StatusCode or "unknown"})
    end

    return {}
end

-- Отметить сервер как посещенный
function Tools.markServerVisited(serverId, placeId, playerCount)
    if not httprequest then
        warn("[SERVERS] HTTP функция недоступна!")
        return false
    end

    local botId = player and player.Name or "unknown"
    local url = Tools.apiUrl .. "/servers/visit?server_id=" .. HttpService:UrlEncode(serverId) .. "&bot_id=" .. HttpService:UrlEncode(botId)
    if placeId then
        url = url .. "&place_id=" .. tostring(placeId)
    end
    if playerCount then
        url = url .. "&player_count=" .. tostring(playerCount)
    end

    local success, response = pcall(function()
        return httprequest({
            Url = url,
            Method = "POST",
            Headers = {
                ["Authorization"] = "Bearer " .. Tools.apiKey,
                ["Content-Type"] = "application/json"
            }
        })
    end)

    if success and response.StatusCode == 200 then
        Tools.logDebug("Сервер отмечен как посещенный", {category = "SERVERS", server_id = serverId})
        return true
    else
        Tools.logWarning("Ошибка записи сервера", {category = "SERVERS", server_id = serverId, status = response and response.StatusCode or "unknown"})
        return false
    end
end

-- Получить сохраненный курсор из локального хранилища
function Tools.getSavedCursor(placeId)
    local checkfile = isfile or isfile_custom or (syn and syn.is_file)
    local read = readfile or read_file or (syn and syn.read_file)

    if not checkfile or not read then
        Tools.logWarning("Функции работы с файлами недоступны", {category = "CURSOR"})
        return nil
    end

    local filename = "cursor_" .. tostring(placeId) .. ".json"

    local success, fileExists = pcall(function()
        return checkfile(filename)
    end)

    if success and fileExists then
        local readSuccess, cursorData = pcall(function()
            return read(filename)
        end)

        if readSuccess and cursorData and cursorData ~= "" then
            local decodeSuccess, data = pcall(function()
                return HttpService:JSONDecode(cursorData)
            end)

            if decodeSuccess and data then
                return {cursor = data.cursor, pageNumber = data.pageNumber}
            else
                Tools.logWarning("Ошибка декодирования JSON", {category = "CURSOR", filename = filename})
            end
        else
            Tools.logWarning("Ошибка чтения файла", {category = "CURSOR", filename = filename})
        end
    else
        Tools.logDebug("Файл курсора не существует", {category = "CURSOR", filename = filename})
    end

    return nil
end

-- Сохранить курсор в локальное хранилище
function Tools.saveCursor(placeId, cursor, pageNumber)
    local write = writefile or write_file or (syn and syn.write_file)

    if not write then
        Tools.logWarning("Функция записи файлов недоступна", {category = "CURSOR"})
        return false
    end

    local filename = "cursor_" .. tostring(placeId) .. ".json"
    local data = {
        cursor = cursor,
        pageNumber = pageNumber,
        timestamp = os.time()
    }

    local success = pcall(function()
        local jsonData = HttpService:JSONEncode(data)
        write(filename, jsonData)
    end)

    if not success then
        Tools.logError("Ошибка сохранения курсора", {category = "CURSOR", filename = filename})
    end

    return success
end

-- Очистить курсор из локального хранилища
function Tools.clearCursor(placeId)
    local delfile = delfile or delete_file or (syn and syn.delete_file)
    
    if not delfile then
        return false
    end

    local filename = "cursor_" .. tostring(placeId) .. ".json"

    local success = pcall(function()
        delfile(filename)
    end)

    return success
end

-- ============================================
-- ФУНКЦИИ ДЛЯ РАБОТЫ С СООБЩЕНИЯМИ
-- ============================================

-- Получить обычное сообщение (камуфляж)
function Tools.getCasualMessage()
    if not httprequest then
        return "hi"
    end

    local success, response = pcall(function()
        return httprequest({
            Url = Tools.apiUrl .. "/messages/casual",
            Method = "GET",
            Headers = {
                ["Authorization"] = "Bearer " .. Tools.apiKey,
                ["Content-Type"] = "application/json"
            }
        })
    end)

    if success and response.StatusCode == 200 then
        local ok, data = pcall(function()
            return HttpService:JSONDecode(response.Body)
        end)

        if ok and data.success then
            return data.message
        end
    end

    return "hi"
end

-- Получить рекламное сообщение из базы
function Tools.getAdMessage()
    if not httprequest then
        warn("[AD] HTTP функция недоступна!")
        return nil
    end

    local success, response = pcall(function()
        return httprequest({
            Url = Tools.apiUrl .. "/messages/get",
            Method = "GET",
            Headers = {
                ["Authorization"] = "Bearer " .. Tools.apiKey,
                ["Content-Type"] = "application/json"
            }
        })
    end)

    if success and response.StatusCode == 200 then
        local ok, data = pcall(function()
            return HttpService:JSONDecode(response.Body)
        end)

        if ok and data.success then
            return {
                id = data.id,
                message = data.message
            }
        end
    end

    return nil
end

-- Отметить сообщение как использованное (запускает период остывания)
function Tools.markAdMessageUsed(messageId)
    if not httprequest then
        return false
    end

    local success, response = pcall(function()
        return httprequest({
            Url = Tools.apiUrl .. "/messages/used/" .. tostring(messageId),
            Method = "POST",
            Headers = {
                ["Authorization"] = "Bearer " .. Tools.apiKey,
                ["Content-Type"] = "application/json"
            }
        })
    end)

    return success and response.StatusCode == 200
end

-- Деактивировать сообщение (если заблокировано фильтром)
function Tools.deactivateAdMessage(messageId)
    if not httprequest then
        return false
    end

    local success, response = pcall(function()
        return httprequest({
            Url = Tools.apiUrl .. "/messages/deactivate/" .. tostring(messageId),
            Method = "POST",
            Headers = {
                ["Authorization"] = "Bearer " .. Tools.apiKey,
                ["Content-Type"] = "application/json"
            }
        })
    end)

    return success and response.StatusCode == 200
end

-- ============================================
-- ФУНКЦИИ ДЛЯ ПАРСИНГА ЧАТА
-- ============================================

-- Буфер для хранения последних сообщений чата
Tools.chatMessageBuffer = {}
Tools.chatBufferMaxSize = 50
Tools.chatListenerConnected = false

-- Подключить слушатель чата (вызывается один раз)
function Tools.connectChatListener()
    if Tools.chatListenerConnected then
        return true
    end

    local TextChatService = game:GetService("TextChatService")

    -- Пробуем подключиться к TextChatService (новый чат Roblox)
    local success = pcall(function()
        local channels = TextChatService:WaitForChild("TextChannels", 5)
        if channels then
            local rbxGeneral = channels:FindFirstChild("RBXGeneral")
            if rbxGeneral then
                rbxGeneral.MessageReceived:Connect(function(textChatMessage)
                    local messageText = textChatMessage.Text or ""
                    local senderName = "Unknown"

                    if textChatMessage.TextSource then
                        local senderId = textChatMessage.TextSource.UserId
                        local senderPlayer = Players:GetPlayerByUserId(senderId)
                        if senderPlayer then
                            senderName = senderPlayer.Name
                        end
                    end

                    -- Добавляем в буфер
                    table.insert(Tools.chatMessageBuffer, 1, {
                        text = messageText,
                        sender = senderName,
                        timestamp = os.time()
                    })

                    -- Ограничиваем размер буфера
                    while #Tools.chatMessageBuffer > Tools.chatBufferMaxSize do
                        table.remove(Tools.chatMessageBuffer)
                    end
                end)

                Tools.chatListenerConnected = true
                return
            end
        end
    end)

    -- Fallback: Legacy chat system
    if not Tools.chatListenerConnected then
        local ReplicatedStorage = game:GetService("ReplicatedStorage")
        local chatEvents = ReplicatedStorage:FindFirstChild("DefaultChatSystemChatEvents")

        if chatEvents then
            local onMessage = chatEvents:FindFirstChild("OnMessageDoneFiltering")
            if onMessage then
                onMessage.OnClientEvent:Connect(function(messageData)
                    local messageText = messageData.Message or messageData.FilteredMessage or ""
                    local senderName = messageData.FromSpeaker or "Unknown"

                    table.insert(Tools.chatMessageBuffer, 1, {
                        text = messageText,
                        sender = senderName,
                        timestamp = os.time()
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
        Tools.logError("Не удалось подключиться к чату", {category = "CHAT_LISTENER"})
    end

    return Tools.chatListenerConnected
end

-- Получить последние сообщения из буфера
function Tools.getRecentChatMessages(count)
    count = count or 10

    -- Подключаем слушатель если ещё не подключен
    if not Tools.chatListenerConnected then
        Tools.connectChatListener()
    end

    local messages = {}
    for i = 1, math.min(count, #Tools.chatMessageBuffer) do
        table.insert(messages, Tools.chatMessageBuffer[i].text)
    end

    return messages
end

function Tools.isMessageFiltered(messages, hashThreshold)
    hashThreshold = hashThreshold or 3


    for idx, msg in ipairs(messages) do
        local hashCount = 0
        local maxConsecutive = 0

        for i = 1, #msg do
            local char = msg:sub(i, i)
            if char == "#" then
                hashCount = hashCount + 1
                if hashCount > maxConsecutive then
                    maxConsecutive = hashCount
                end
            else
                hashCount = 0
            end
        end

        if maxConsecutive > 0 then
            Tools.logDebug("Найдены символы # в сообщении", {category = "FILTER_CHECK", message_idx = idx, hash_count = maxConsecutive})
        end

        if maxConsecutive > hashThreshold then
            Tools.logWarning("Обнаружена фильтрация в сообщении", {category = "FILTER_CHECK", message_idx = idx})
            return true, msg
        end
    end

    Tools.logDebug("Фильтрация не обнаружена", {category = "FILTER_CHECK"})
    return false, nil
end

-- Проверить фильтрацию после отправки рекламы и деактивировать если нужно
function Tools.checkAndDeactivateIfFiltered(adMessageId, waitTime)
    waitTime = waitTime or 2

    Tools.logInfo("Начинаю проверку фильтрации", {category = "FILTER", message_id = adMessageId, wait_time = waitTime})

    -- Ждем пока сообщение появится в чате
    task.wait(waitTime)

    -- Получаем последние 10 сообщений
    local recentMessages = Tools.getRecentChatMessages(10)

    Tools.logDebug("Получено сообщений для анализа", {category = "FILTER", count = #recentMessages})

    if #recentMessages == 0 then
        Tools.logWarning("Не удалось получить сообщения из чата", {category = "FILTER"})
        return false
    end

    -- Проверяем на фильтрацию
    local wasFiltered, filteredMsg = Tools.isMessageFiltered(recentMessages, 3)

    if wasFiltered then
        Tools.logWarning("Фильтрация обнаружена!", {category = "FILTER", message_id = adMessageId, filtered_text = filteredMsg})

        -- Деактивируем сообщение
        if adMessageId then
            local success = Tools.deactivateAdMessage(adMessageId)
            if success then
                Tools.logInfo("Сообщение деактивировано", {category = "FILTER", message_id = adMessageId})
            else
                Tools.logError("Ошибка деактивации сообщения", {category = "FILTER", message_id = adMessageId})
            end
        end

        return true
    else
        Tools.logInfo("Сообщение прошло без фильтрации", {category = "FILTER", message_id = adMessageId})
    end

    return false
end


function Tools.serverHop()
    Tools.logInfo("Начинаю переключение сервера", {category = "HOP"})

    local visitedServers = Tools.getVisitedServers(12)
    local visitedSet = {}
    for _, serverId in ipairs(visitedServers) do
        visitedSet[serverId] = true
    end

    local savedCursor = Tools.getSavedCursor(Tools.placeId)
    local cursor = ""
    local lastSavedCursor = ""
    local pagesChecked = 1

    if savedCursor then
        cursor = savedCursor.cursor
        pagesChecked = savedCursor.pageNumber
        lastSavedCursor = cursor
        if pagesChecked >= 20 then
            Tools.logInfo("Сброс курсора: страница >= 20", {category = "HOP", page = pagesChecked})
            Tools.clearCursor(Tools.placeId)
            cursor = ""
            pagesChecked = 1
        else
            Tools.logDebug("Продолжаю со страницы", {category = "HOP", page = pagesChecked})
        end
    else
        Tools.logDebug("Курсор не найден, начинаю с первой страницы", {category = "HOP"})
    end

    local currentMinPlayers = Tools.minPlayersPreferred
    local consecutiveRateLimits = 0
    Tools.logInfo("Поиск серверов", {category = "HOP", min_players = currentMinPlayers, max_players = Tools.maxPlayersAllowed})

    while true do
        if not Tools.isEnabled() then
            Tools.logInfo("Остановлено пользователем", {category = "HOP"})
            return false
        end

        local url = string.format(
            "https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Desc&limit=100&excludeFullGames=true%s",
            Tools.placeId,
            cursor ~= "" and "&cursor=" .. cursor or ""
        )

        Tools.logDebug("Загрузка страницы", {category = "HOP", page = pagesChecked})

        local success, response = pcall(function()
            return httprequest({Url = url})
        end)

        if success and response.StatusCode == 200 then
            consecutiveRateLimits = 0 
            local data = HttpService:JSONDecode(response.Body)

            local servers = shuffleArray(data.data)

            for _, server in ipairs(servers) do
                local playerCount = server.playing
                local maxPlayers = server.maxPlayers
                local serverId = server.id

                local freeSlots = maxPlayers - playerCount
                local notVisited = not visitedSet[serverId]

                if playerCount >= currentMinPlayers and
                   freeSlots >= 10 and
                   playerCount <= Tools.maxPlayersAllowed and
                   serverId ~= game.JobId and
                   notVisited then

                    Tools.logInfo("Найден подходящий сервер", {
                        category = "HOP",
                        server_id = serverId,
                        players = playerCount,
                        max_players = maxPlayers,
                        free_slots = freeSlots
                    })

                    Tools.markServerVisited(serverId, Tools.placeId, playerCount)

                    local teleportSuccess = pcall(function()
                        if not scriptQueued then
                            queueFunc('loadstring(game:HttpGet("' .. Tools.scriptUrl .. '"))()')
                            scriptQueued = true
                        end
                        TeleportService:TeleportToPlaceInstance(Tools.placeId, serverId, player)
                    end)

                    if teleportSuccess then
    Tools.logInfo("Телепортация на сервер", {category = "HOP", server_id = serverId})
                    return true
                else
                    Tools.logWarning("Ошибка телепортации, продолжаю поиск", {category = "HOP", server_id = serverId})
                end
            end
        end

        if data.nextPageCursor then
                cursor = data.nextPageCursor
                pagesChecked = pagesChecked + 1

                if pagesChecked > 20 then
                    Tools.logInfo("Достигнут лимит страниц, сброс", {category = "HOP", page = pagesChecked})
                    Tools.clearCursor(Tools.placeId)
                    cursor = ""
                    pagesChecked = 1
                else
                    if cursor ~= "" and cursor ~= lastSavedCursor then
                        Tools.saveCursor(Tools.placeId, cursor, pagesChecked)
                        lastSavedCursor = cursor
                        Tools.logDebug("Прогресс сохранён", {category = "HOP", page = pagesChecked})
                    end
                end
            else
                Tools.logInfo("Достигнут конец списка, начинаю сначала", {category = "HOP"})
                Tools.clearCursor(Tools.placeId)
                cursor = ""
                pagesChecked = 1
            end
        elseif success and response.StatusCode == 429 then
            consecutiveRateLimits = consecutiveRateLimits + 1
            local waitTime = math.min(10 * (2 ^ (consecutiveRateLimits - 1)), 120)
            Tools.logWarning("Rate limit, ожидание", {category = "HOP", wait_seconds = waitTime, attempt = consecutiveRateLimits})

            for _ = 1, waitTime do
                if not Tools.isEnabled() then
                    Tools.logInfo("Остановлено во время ожидания", {category = "HOP"})
                    return false
                end
                task.wait(1)
            end
        else
            consecutiveRateLimits = 0
            Tools.logError("Ошибка HTTP запроса", {category = "HOP", status = response and response.StatusCode or "unknown"})
            task.wait(5)
        end
    end
end


-- Автоматический реконнект при ошибке соединения
function Tools.autoReconnect()
    local GuiService = game:GetService("GuiService")

    -- Ошибки при которых НЕ нужно переподключаться (кик, бан, дубликат и т.д.)
    local noReconnectErrors = {
        [Enum.ConnectionError.DisconnectLuaKick]              = true,
        [Enum.ConnectionError.DisconnectSecurityKeyMismatch]  = true,
        [Enum.ConnectionError.DisconnectNewSecurityKeyMismatch] = true,
        [Enum.ConnectionError.DisconnectDuplicateTicket]      = true,
        [Enum.ConnectionError.DisconnectWrongVersion]         = true,
        [Enum.ConnectionError.DisconnectProtocolMismatch]     = true,
        [Enum.ConnectionError.DisconnectIllegalTeleport]      = true,
        [Enum.ConnectionError.DisconnectDuplicatePlayer]      = true,
    }

    -- Симуляция реального клика мышью по кнопке через VirtualInputManager
    local function clickCoreGuiButton(btn)
        local pos      = btn.AbsolutePosition
        local size     = btn.AbsoluteSize
        local guiInset = GuiService:GetGuiInset()
        local cx       = pos.X + size.X / 2
        local cy       = pos.Y + size.Y / 2 + guiInset.Y

        -- VirtualInputManager: реальная симуляция клика (работает с CoreGui)
        pcall(function()
            VirtualInputManager:SendMouseButtonEvent(cx, cy, 0, true,  game, 1)
            task.wait(0.05)
            VirtualInputManager:SendMouseButtonEvent(cx, cy, 0, false, game, 1)
        end)

        -- firesignal (Synapse X / Wave)
        pcall(function()
            if firesignal then firesignal(btn.MouseButton1Click) end
        end)

        -- Fallback: стандартный fire
        pcall(function() btn.MouseButton1Click:Fire() end)
        pcall(function() btn:Activate() end)
    end

    -- Попытка найти и кликнуть кнопку Reconnect: сначала точный путь, затем сканирование
    local function tryClickReconnect()
        pcall(function()
            local cg = game:GetService("CoreGui")

            -- Точный путь: RobloxPromptGui → promptOverlay → ErrorPrompt → ... → ReconnectButton
            local promptGui = cg:FindFirstChild("RobloxPromptGui")
            if promptGui then
                local overlay    = promptGui:FindFirstChild("promptOverlay")
                local errorPrompt = overlay and overlay:FindFirstChild("ErrorPrompt")
                local buttonArea = errorPrompt and errorPrompt:FindFirstChild("ButtonArea", true)
                if buttonArea then
                    local btn = buttonArea:FindFirstChild("ReconnectButton")
                        or buttonArea:FindFirstChild("Reconnect")
                    if btn then
                        Tools.logWarning("Реконнект: клик по ReconnectButton (точный путь)", {category = "RECONNECT"})
                        clickCoreGuiButton(btn)
                        return
                    end
                end
            end

            -- Fallback: перебираем всех потомков CoreGui
            for _, obj in pairs(cg:GetDescendants()) do
                if obj:IsA("TextButton") or obj:IsA("ImageButton") then
                    local t = string.lower(obj.Text or obj.Name or "")
                    if string.find(t, "reconnect") or string.find(t, "переподключ") then
                        Tools.logWarning("Реконнект: клик через сканирование", {
                            category = "RECONNECT",
                            button_text = obj.Text or "",
                            button_name = obj.Name
                        })
                        clickCoreGuiButton(obj)
                        return
                    end
                end
            end
        end)
    end

    -- Проверка: виден ли экран ошибки прямо сейчас
    local function isErrorVisible()
        local visible = false
        pcall(function()
            local cg = game:GetService("CoreGui")
            local promptGui = cg:FindFirstChild("RobloxPromptGui")
            local overlay   = promptGui and promptGui:FindFirstChild("promptOverlay")
            local errorPrompt = overlay and overlay:FindFirstChild("ErrorPrompt")
            visible = errorPrompt ~= nil
        end)
        return visible
    end

    -- Основной слушатель: срабатывает мгновенно при появлении экрана ошибки
    -- После срабатывания запускает цикл повторных попыток пока ошибка висит
    pcall(function()
        GuiService.ErrorMessageChanged:Connect(function()
            local errorCode = GuiService:GetErrorCode()
            Tools.logWarning("Ошибка соединения обнаружена", {
                category = "RECONNECT",
                error_code = tostring(errorCode)
            })
            if noReconnectErrors[errorCode] then
                Tools.logWarning("Реконнект пропущен: тип ошибки не допускает повторное подключение", {
                    category = "RECONNECT",
                    error_code = tostring(errorCode)
                })
                return
            end
            task.spawn(function()
                task.wait(1.5)
                local attempts = 0
                while isErrorVisible() and attempts < 20 do
                    attempts = attempts + 1
                    Tools.logWarning("Реконнект: попытка " .. attempts, {category = "RECONNECT"})
                    tryClickReconnect()
                    task.wait(3)
                end
                if attempts > 0 and not isErrorVisible() then
                    Tools.logInfo("Реконнект: ошибка устранена", {category = "RECONNECT", attempts = attempts})
                end
            end)
        end)
    end)

    -- Резервный цикл на случай если событие не сработало
    task.spawn(function()
        while true do
            task.wait(3)
            pcall(function()
                local cg = game:GetService("CoreGui")
                for _, obj in pairs(cg:GetDescendants()) do
                    if obj:IsA("TextButton") or obj:IsA("ImageButton") then
                        local t = string.lower(obj.Text or obj.Name or "")
                        if string.find(t, "reconnect") or string.find(t, "переподключ") then
                            Tools.logWarning("Реконнект: резервный цикл обнаружил кнопку", {
                                category = "RECONNECT",
                                button_text = obj.Text or "",
                                button_name = obj.Name
                            })
                            clickCoreGuiButton(obj)
                            task.wait(5)
                        end
                    end
                end
            end)
        end
    end)
end


return Tools