Json = Json or VFS.Include('common/luaUtilities/json.lua')

local widget = widget ---@type Widget

function widget:GetInfo()
    return {
        name = "Chat Filter",
        desc = "Censors, modifies or blocks chat messages based on user-defined rules.",
        author = "uBdead",
        date = "2025-11-13",
        license = "GNU GPL, v2 or later",
        layer = 0,
        enabled = true
    }
end

local filter = {}
local filterMode = 0 -- 0: censor, 1: block, 2: kitty
local connected = false
local client = nil
local set = nil
local chatBuffer = {}
local ourName = Spring.GetPlayerInfo(Spring.GetMyPlayerID(), false)

local spEcho = Spring.Echo

local function rot13(str)
    return (str:gsub("%a", function(c)
        if c:match("[A-Za-z]") then
            local base = c:match("%l") and string.byte('a') or string.byte('A')
            return string.char(((string.byte(c) - base + 13) % 26) + base)
        else
            return c
        end
    end))
end

local function newset()
    local reverse = {}
    local set = {}
    return setmetatable(set, {
        __index = {
            insert = function(set, value)
                if not reverse[value] then
                    table.insert(set, value)
                    reverse[value] = table.getn(set)
                end
            end,
            remove = function(set, value)
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

local function SocketConnect(host, port)
    client = socket.tcp()
    client:settimeout(0)
    local res, err = client:connect(host, port)
    if not res and err ~= "timeout" then
        client:close()
        spEcho("Unable to connect to Beyond All Rage server: ", res, err, "Falling back to local mode")
        client = nil
        connected = false
        filterMode = 0
        return false
    end
    set = newset()
    set:insert(client)
    connected = true

    spEcho("Connected to Beyond All Rage server", res, err)
    return true
end

local function cleanText(text)
    -- strip out unwanted bytes, so anything not [azA-Z0-9 .,!?'-]
    return text:gsub("[^%a%d .,!?'-]", "")
end

local function beyondAllRage(gameFrame, lineType, name, nameText, text, orgLineID, ignore, chatLineID)
    if not connected then
        return text
    end

    chatBuffer[chatLineID] = {
        gameFrame = gameFrame,
        lineType = lineType,
        name = name,
        nameText = nameText,
        orgLineID = orgLineID,
        ignore = ignore,
    }

    local encoded = Json.encode({
        id = chatLineID,
        text = cleanText(text)
    })
    client:send(encoded)

    return nil
end

function widget:Initialize()
    if WG.options and WG.options.addOption then
        WG.options.addOption({
            id = "chat_filter_mode",
            group = "custom",
            category = "basic",
            name = "Chat Filter Mode",
            type = "select",
            options = { "Censor", "Block", "Kitty", "BeyondAllRage" },
            value = filterMode + 1,
            description = "Choose how chat messages are filtered.",
            onchange = function(i, value)
                filterMode = value - 1
                if filterMode == 3 then
                    SocketConnect("beyondallrage.zen-ben.com", 8696)
                elseif client then
                    client:close()
                    client = nil
                    connected = false
                end
            end,
        })
    end

    local data = VFS.LoadFile("LuaUI/Widgets/gui_chat_filter/filter.txt")
    if data == nil then
        Spring.Echo("Filter file not found!")
        return
    end

    -- split the text into lines
    for line in data:gmatch("[^\r\n]+") do
        line = line:match("^%s*(.-)%s*$")            -- trim whitespace
        if line:sub(1, 1) ~= "#" and line ~= "" then -- ignore comments and empty lines
            if line:sub(1, 1) == "@" then
                line = rot13(line:sub(2))
            else
                line = line
            end
            filter[line] = true
        end
    end

    WG['chat'].addChatProcessor("chat_filter",
        function(gameFrame, lineType, name, nameText, text, orgLineID, ignore, chatLineID)
            if name == ourName and not name == "uBdead" then
                return text
            end

            if filterMode == 3 then
                return beyondAllRage(gameFrame, lineType, name, nameText, text, orgLineID, ignore, chatLineID)
            end

            for word in pairs(filter) do
                if text:lower():find(word:lower()) then
                    if filterMode == 0 then
                        text = text:gsub("(%f[%w])" .. word .. "(%f[%W])", "%1****%2")
                    elseif filterMode == 1 then
                        return nil
                    elseif filterMode == 2 then
                        text = text:gsub("(%f[%w])" .. word .. "(%f[%W])", "%1 :X %2")
                    end
                end
            end

            return text
        end)

    if filterMode == 3 then
        SocketConnect("beyondallrage.zen-ben.com", 8696)
    end
end

function widget:Update(dt)
    if set == nil or #set <= 0 then
        return
    end
    local readable, writeable, err = socket.select(set, set, 0)
    if err ~= nil then
        if err == "timeout" then
            return
        end
        spEcho("Error in select: " .. error)
    end
    for _, input in ipairs(readable) do
        local s, status, partial = input:receive('*a') --try to read all data
        if status == "timeout" or status == nil then
            local data = s or partial

            local decoded = Json.decode(data)
            local chatLineID = decoded.id
            local filteredText = cleanText(decoded.text)
            local chatData = chatBuffer[chatLineID]
            if chatData then
                WG['chat'].addChatLine(
                    chatData.gameFrame,
                    chatData.lineType,
                    chatData.name,
                    chatData.nameText,
                    filteredText,
                    chatData.orgLineID,
                    chatData.ignore,
                    chatLineID
                )
                chatBuffer[chatLineID] = nil
            end
        elseif status == "closed" then
            input:close()
            set:remove(input)
        end
    end
end

function widget:Shutdown()
    WG['chat'].removeChatProcessor("chat_filter")

    if client then
        client:close()
        client = nil
    end
end
