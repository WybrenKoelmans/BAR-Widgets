Json = Json or VFS.Include('common/luaUtilities/json.lua')

local widget = widget ---@type Widget

function widget:GetInfo()
    return {
        name = "Translate Chat",
        desc = "Translates incoming chat messages using a local LibreTranslate instance.",
        author = "uBdead",
        date = "2026-07-04",
        license = "GNU GPL, v2 or later",
        layer = 0,
        enabled = false
    }
end

local chatBuffer = {}
local pendingRequests = {}
local responseBuffers = {}
local connectingSet = nil -- sockets still connecting/sending (watched for writability)
local pendingSet = nil    -- sockets whose request was fully sent (watched for readability)

local REQUEST_TIMEOUT_SECONDS = 15

local ourName = Spring.GetPlayerInfo(Spring.GetMyPlayerID(), false)

local libreTranslateHost = "libretranslate.zen-ben.com:80"
local translateIncomingTo = "en"
local translateOutgoingTo = "en"
local replaceOriginalMessages = false

local targetLangs = { "off",
    "sq", "ar", "az", "eu", "bn", "bg", "ca", "zh-Hans", "zh-Hant", 
    "cs", "da", "nl", "en", "eo", "et", "fa", "fi", "fr", "gl", 
    "de", "el", "he", "hi", "hu", "id", "ga", "it", "ja", "ko", 
    "ky", "lv", "lt", "ms", "nb", "pl", "pt", "ro", "ru", "sk", 
    "sl", "es", "sw", "sv", "tl", "th", "tr", "uk", "ur", "vi"
}

local targetLangNames = { "Off",
    "Albanian", "Arabic", "Azerbaijani", "Basque", "Bengali", "Bulgarian", "Catalan", "Chinese (Simplified)", "Chinese (Traditional)", 
    "Czech", "Danish", "Dutch", "English", "Esperanto", "Estonian", "Persian", "Finnish", "French", "Galician", 
    "German", "Greek", "Hebrew", "Hindi", "Hungarian", "Indonesian", "Irish", "Italian", "Japanese", "Korean", 
    "Kyrgyz", "Latvian", "Lithuanian", "Malay", "Norwegian Bokmål", "Polish", "Portuguese", "Romanian", "Russian", "Slovak", 
    "Slovenian", "Spanish", "Swahili", "Swedish", "Tagalog", "Thai", "Turkish", "Ukrainian", "Urdu", "Vietnamese"
}

local LineTypes = {
	Console = -1,
	Player = 1,
	Spectator = 2,
	Mapmark = 3,
	Battleroom = 4,
	System = 5
}

-- Forward register the function names
local newSet
local parseHostPort
local getLangIndex
local registerOptions
local removeOptions
local processResponse
local makeTranslateRequest

local optionsRegistered = false

local spEcho = Spring.Echo

-- Returns the leading Spring color code (\255 + 3 RGB bytes) from a text string,
-- or an empty string if there is none.
local function getTextColorPrefix(text)
    if text and text:sub(1, 1) == '\255' and #text >= 4 then
        return text:sub(1, 4)
    end
    return ''
end

-- Returns the text with the leading Spring color code stripped.
local function getTextContent(text)
    if text and text:sub(1, 1) == '\255' and #text >= 4 then
        return text:sub(5)
    end
    return text or ''
end

-- Converts JSON \uXXXX Unicode escapes to UTF-8 bytes.
-- json.lua strips the backslash but leaves 'uXXXX' as literal text;
-- pre-processing the raw body before Json.decode avoids that.
local function decodeUnicodeEscapes(str)
    return str:gsub("\\u(%x%x%x%x)", function(hex)
        local cp = tonumber(hex, 16)
        if cp < 0x80 then
            return string.char(cp)
        elseif cp < 0x800 then
            return string.char(
                0xC0 + math.floor(cp / 64),
                0x80 + cp % 64
            )
        else
            return string.char(
                0xE0 + math.floor(cp / 4096),
                0x80 + math.floor(cp % 4096 / 64),
                0x80 + cp % 64
            )
        end
    end)
end

-- Derives the Spring SendCommands chat mode prefix (e.g. 'a:', 's:', or '')
-- from the color code that gui_chat prepends to the text:
--   colorAlly  {0,1,0}   → R=0,   G=255, B=0   → allies
--   colorSpec  {1,1,0}   → R=255, G=255, B=0   → spectators
--   everything else                              → all (no prefix)
local function getInputModeFromText(text)
    local prefix = getTextColorPrefix(text)
    if #prefix < 4 then return '' end
    local r, g, b = prefix:byte(2), prefix:byte(3), prefix:byte(4)
    if r == 0   and g == 255 and b == 0   then return 'a:' end  -- allies
    if r == 255 and g == 255 and b == 0   then return 's:' end  -- spectators
    return ''
end

function widget:Initialize()
    pendingSet = newSet()
    connectingSet = newSet()
    registerOptions()

    WG['chat'].addChatProcessor(
        "translate_chat",
        function (gameFrame, lineType, name, nameText, text, orgLineID, ignore, chatLineID)
            return makeTranslateRequest(gameFrame, lineType, name, nameText, text, orgLineID, ignore, chatLineID)
        end
    )
end

makeTranslateRequest = function (gameFrame, lineType, name, nameText, text, orgLineID, ignore, chatLineID)
    -- Only translate player chat, spectator chat, and map marks
    if lineType ~= LineTypes.Player and lineType ~= LineTypes.Spectator and lineType ~= LineTypes.Mapmark then
        return text
    end

    local tLang = name == ourName and translateOutgoingTo or translateIncomingTo
    if tLang == "off" then
        -- spEcho("[TranslateChat] Translation is off for chat line " .. tostring(chatLineID))
        return text
    end

    -- check for [T]: because it means the message is already a translation, so we don't want to translate it again
    if text:find("%[T%]") then
        -- spEcho("[TranslateChat] Skipping translation for chat line " .. tostring(chatLineID) .. " because it is already a translation.")
        return text
    end

    local host, port = parseHostPort(libreTranslateHost)

    -- Strip Spring color/control codes while preserving full UTF-8 text (Cyrillic, CJK, etc.)
    local clean = getTextContent(text)           -- remove leading \255 RGB prefix
    clean = clean:gsub("\255...", "")            -- inline color codes  (\255 + 3 bytes)
    clean = clean:gsub("\254........", "")       -- extended color codes (\254 + 8 bytes)
    clean = clean:gsub("[\n\r]+", " ")           -- normalize newlines to spaces (invalid in JSON strings)
    clean = clean:gsub("%c", "")                 -- strip remaining ASCII control characters
    clean = clean:match("^%s*(.-)%s*$")          -- trim leading/trailing whitespace

    -- Skip empty messages (e.g. multi-line chat split across AddConsoleLine calls)
    if clean == "" then
        return text
    end

    -- Skip Spring i18n system messages (e.g. energy/metal share: "> :ui.playersList.chat.give...")
    if clean:sub(1, 2) == '> ' then
        return text
    end

    local conn = socket.tcp()
    conn:settimeout(0)
    local ok, err = conn:connect(host, port)
    if not ok and err ~= "timeout" and err ~= "already connected" then
        conn:close()
        spEcho("[TranslateChat] Failed to connect to " .. libreTranslateHost .. ": " .. tostring(err))
        return text
    end

    local body = Json.encode({
        q = clean,
        source = "auto",
        target = tLang,
        format = "text",
        alternatives = 0,
    })

    local request = table.concat({
        "POST /translate HTTP/1.1",
        "Host: " .. host .. ":" .. port,
        "Content-Type: application/json",
        "Content-Length: " .. #body,
        "Connection: close",
        "",
        body
    }, "\r\n")

    -- spEcho("[TranslateChat] Sending translation request for chat line " .. tostring(chatLineID) .. " to " .. libreTranslateHost .. " (target language: " .. tLang .. ")")
    -- The socket is non-blocking, so the TCP handshake is still in progress here
    -- and sending now would transmit nothing. Queue the request; widget:Update
    -- sends it once select() reports the socket writable.
    pendingRequests[conn] = {
        request = request,
        sendPos = 1,
        startTimer = Spring.GetTimer()
    }
    responseBuffers[conn] = ""
    connectingSet:insert(conn)

    chatBuffer[conn] = {
        gameFrame = gameFrame,
        lineType = lineType,
        name = name,
        nameText = nameText,
        text = text,
        orgLineID = orgLineID,
        chatLineID = chatLineID,
        ignore = ignore
    }

    return text
end

processResponse = function(conn)
    local data = responseBuffers[conn] or ""
    local chatData = chatBuffer[conn]

    if not chatData then return end

    local headerEnd = data:find("\r\n\r\n", 1, true)
    if not headerEnd then return end

    local headers = data:sub(1, headerEnd - 1)
    local body = data:sub(headerEnd + 4)

    -- Handle chunked transfer encoding
    if headers:lower():find("transfer%-encoding:%s*chunked") then
        local chunks = {}
        local pos = 1
        while pos <= #body do
            local lineEnd = body:find("\r\n", pos, true)
            if not lineEnd then break end
            local sizeHex = body:sub(pos, lineEnd - 1):match("^%s*(%x+)")
            if not sizeHex then break end
            local size = tonumber(sizeHex, 16)
            if not size or size == 0 then break end
            pos = lineEnd + 2
            table.insert(chunks, body:sub(pos, pos + size - 1))
            pos = pos + size + 2
        end
        body = table.concat(chunks)
    end

    body = decodeUnicodeEscapes(body)

    local decoded = Json.decode(body)
    local translated = decoded and decoded.translatedText
    
    if translated then
        if chatData then
            chatBuffer[conn] = nil

            -- If the translation equals the original text, don't add a new line or re-send it.
            if translated == getTextContent(chatData.text) then
                return
            end

            if chatData.name == ourName then
                -- Re-send the translation on the same channel as the original message,
                -- marked with [T] so recipients know it is a translation.
                local inputMode = getInputModeFromText(chatData.text)
                Spring.SendCommands("say " .. inputMode .. "[T] " .. translated)
            else 
                -- spEcho("[TranslateChat] " .. chatData.name .. ": " .. getTextContent(chatData.text), chatData)
                local colorPrefix = getTextColorPrefix(chatData.text)
                local chatLineID = replaceOriginalMessages and chatData.chatLineID or nil
                local text
                if not replaceOriginalMessages then
                    text = colorPrefix .. "[T] " .. translated
                else 
                    text = colorPrefix .. translated
                end
                WG['chat'].addChatLine(chatData.gameFrame, chatData.lineType, chatData.name, chatData.nameText, text, chatData.orgLineID, chatData.ignore, chatLineID)
            end
        end
    else
        spEcho("[TranslateChat] Failed to decode translation response")
        spEcho("[TranslateChat] Response body: " .. tostring(body))
    end
end

local function closeRequest(conn)
    connectingSet:remove(conn)
    pendingSet:remove(conn)
    pendingRequests[conn] = nil
    responseBuffers[conn] = nil
    chatBuffer[conn] = nil
    conn:close()
end

function widget:Update(dt)
    if pendingSet == nil or (#pendingSet == 0 and #connectingSet == 0) then
        return
    end

    local readable, writable, err = socket.select(pendingSet, connectingSet, 0)
    if err ~= nil and err ~= "timeout" then
        spEcho("[TranslateChat] Select error: " .. tostring(err))
        return
    end

    -- Handshake completed: send the request (resuming after partial sends)
    for _, conn in ipairs(writable) do
        local pending = pendingRequests[conn]
        if pending then
            local sent, sendErr, lastByte = conn:send(pending.request, pending.sendPos)
            if sent then
                connectingSet:remove(conn)
                pendingSet:insert(conn)
            elseif sendErr == "timeout" then
                pending.sendPos = (lastByte or (pending.sendPos - 1)) + 1
            else
                spEcho("[TranslateChat] Failed to send request: " .. tostring(sendErr))
                closeRequest(conn)
            end
        end
    end

    for _, conn in ipairs(readable) do
        local data, status, partial = conn:receive('*a')
        responseBuffers[conn] = (responseBuffers[conn] or "") .. (data or partial or "")

        -- receive('*a') succeeds (status == nil) or reports "closed" once the
        -- server closes the connection; "timeout" means more data may follow.
        if status ~= "timeout" then
            processResponse(conn)
            closeRequest(conn)
        end
    end

    -- Drop requests that never completed (e.g. unreachable or unresponsive host)
    local now = Spring.GetTimer()
    for conn, pending in pairs(pendingRequests) do
        if Spring.DiffTimers(now, pending.startTimer) > REQUEST_TIMEOUT_SECONDS then
            spEcho("[TranslateChat] Request timed out after " .. REQUEST_TIMEOUT_SECONDS .. "s")
            processResponse(conn)
            closeRequest(conn)
        end
    end
end

function widget:GetConfigData()
    return {
        libreTranslateHost = libreTranslateHost,
        translateIncomingTo = translateIncomingTo,
        translateOutgoingTo = translateOutgoingTo,
        replaceOriginalMessages = replaceOriginalMessages,
    }
end

function widget:SetConfigData(data)
    if data then
        if data.libreTranslateHost then libreTranslateHost = data.libreTranslateHost end
        if data.translateIncomingTo then translateIncomingTo = data.translateIncomingTo end
        if data.translateOutgoingTo then translateOutgoingTo = data.translateOutgoingTo end
        if data.replaceOriginalMessages ~= nil then replaceOriginalMessages = data.replaceOriginalMessages end
    end
end

function widget:Shutdown()
    removeOptions()
    WG['chat'].removeChatProcessor("translate_chat")

    for conn in pairs(pendingRequests) do
        pcall(function ()
                conn:close()
            end)
    end

    pendingRequests = {}
    responseBuffers = {}
end

registerOptions = function ()
    if not WG['options'] or not WG['options'].addOptions then
        return false
    end
    WG['options'].addOptions({
        {
            id = "translate_chat_target_lang",
            widgetname = "Translate Chat",
            name = "Incoming",
            type = "select",
            options = targetLangNames,
            value = getLangIndex(translateIncomingTo),
            description = "Translate incoming chat messages into...",
            onchange = function (_, value)
                translateIncomingTo = targetLangs[value]
            end
        },
        {
            id = "translate_chat_outgoing_lang",
            widgetname = "Translate Chat",
            name = "Outgoing",
            type = "select",
            options = targetLangNames,
            value = getLangIndex(translateOutgoingTo),
            description = "Translate your outgoing messages into...",
            onchange = function (_, value)
                translateOutgoingTo = targetLangs[value]
            end
        },
        {
            id = "translate_chat_host",
            widgetname = "Translate Chat",
            name = "Use (public) community server",
            type = "bool",
            value = libreTranslateHost == "libretranslate.zen-ben.com:80" and 1 or 0,
            description = "Use local server or public server for translations. \n\nPrivate local server must be running on port 5000.",
            onchange = function (_, value)
                spEcho("[TranslateChat] Changing translation server to " .. (value == true and "public" or "local") .. " server.")
                if value == true then
                    libreTranslateHost = "libretranslate.zen-ben.com:80"
                else
                    libreTranslateHost = "localhost:5000"
                end
            end
        }, 
        {
            id = "translate_chat_replace",
            widgetname = "Translate Chat",
            name = "Replace original messages",
            type = "bool",
            value = replaceOriginalMessages and 1 or 0,
            description = "Replace original messages with translated ones. \n\nIf disabled, translated messages will be shown as a separate line.",
            onchange = function (_, value)
                replaceOriginalMessages = value == true
                spEcho("[TranslateChat] Changing message replacement to " .. (replaceOriginalMessages and "enabled" or "disabled") .. ".")
            end
        }
    })
    optionsRegistered = true
    return true
end

removeOptions = function ()
    if WG['options'] and WG['options'].removeOptions then
        WG['options'].removeOptions({
            "translate_chat_label",
            "translate_chat_target_lang",
            "translate_chat_outgoing_lang",
            "translate_chat_host",
            "translate_chat_replace"
        })
    end
end

newSet = function ()
    local reverse = {}
    local set = {}
    return setmetatable(set, {
        __index = {
            insert = function (set, value)
                if not reverse[value] then
                    table.insert(set, value)
                    reverse[value] = #set
                end
            end,
            remove = function (set, value)
                local index = reverse[value]
                if index then
                    reverse[value] = nil
                    local top = table.remove(set)
                    if top ~= value then
                        reverse[top] = index
                        set[index] = top
                    end
                end
            end
        }
    })
end

parseHostPort = function (hostStr)
    local host, port = hostStr:match("^(.+):(%d+)$")
    if host then
        return host, tonumber(port)
    end
    return hostStr, 5000
end

getLangIndex = function (lang)
    for i, l in ipairs(targetLangs) do
        if l == lang then return i end
    end
    return 1
end

getHostIndex = function (host)
    for i, h in ipairs(libreTranslateHosts) do
        if h == host then return i end
    end
    return 1
end
