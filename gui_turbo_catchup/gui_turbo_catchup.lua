local widget = widget ---@type Widget

function widget:GetInfo()
    return {
        name = "Turbo Catchup",
        desc = "Disables all widgets during catchup to maximize performance.",
        author = "uBdead",
        date = "2026-08-04",
        license = "GNU GPL, v2 or later",
        layer = 0,
        enabled = true,
        handler = true, -- we need to be a handler to disable other widgets
    }
end

local widgetWhitelist = {
    ["Turbo Catchup"] = true,   -- we need to be able to enable ourselves
    ["Rejoin progress"] = true, -- we want to show the rejoin progress during catchup
    ["Chat"] = true,            -- we want to be able to see chat messages during catchup, doesn't reload cleanly
}
local serverFrame = 0
local turboActive = false
local CATCH_UP_THRESHOLD = 3 * Game.gameSpeed
local frameRate = 0
local lastFrame = 0
local window = 0

local spGetGameFrame = Spring.GetGameFrame
local disabledWidgets = {} -- to keep track of which widgets we disabled so we can re-enable them later

local function GetWidgetToggleValue(widgetname)
    if widgetHandler.orderList[widgetname] == nil or widgetHandler.orderList[widgetname] == 0 then
        return false
    elseif widgetHandler.orderList[widgetname] >= 1
        and widgetHandler.knownWidgets ~= nil
        and widgetHandler.knownWidgets[widgetname] ~= nil then
        if widgetHandler.knownWidgets[widgetname].active then
            return true
        else
            return 0.5
        end
    end
end

local function catchupMode()
    if turboActive then return end -- already in catchup mode, no need to do anything

    Spring.Echo("Enabling turbo catchup mode, too far behind server: " .. (serverFrame - spGetGameFrame()) .. " frames behind")

    -- enable catchup mode
    turboActive = true
    for name, data in pairs(widgetHandler.knownWidgets) do
        local state = GetWidgetToggleValue(name)
        local realState = 0
        if state == false then
            realState = 0  -- disabled
        elseif state == 0.5 then
            realState = -1 -- errored
        else
            realState = 1  -- enabled
        end

        if not widgetWhitelist[name] and realState >= 1 then
            widgetHandler:DisableWidget(name)
            disabledWidgets[name] = true
        end
    end
end

local function disableCatchupMode()
    if not turboActive then return end -- not in catchup mode, no need to do anything

    -- disable catchup mode
    turboActive = false
    Spring.Echo("Disabling turbo catchup mode, caught up to server")
    for name, data in pairs(disabledWidgets) do
        if not widgetWhitelist[name] then
            widgetHandler:EnableWidget(name)
            disabledWidgets[name] = nil
            -- Spring.Echo("Re-enabled widget: " .. name)
        end
    end
end

function widget:Update(dt)
    local currentFrame = spGetGameFrame()

    -- if serverFrame - currentFrame < Game.gameSpeed * -10 then
        -- we are probably actually catching up and the GameProgress are not arriving due to packet queuing
        -- Spring.Echo("Frames ahead of server: " .. (currentFrame - serverFrame) .. ", enabling catchup mode preemptively")
        -- catchupMode()
    -- end

    window = window + dt
    if window >= 1 then
        frameRate = (currentFrame - lastFrame) / window
        lastFrame = currentFrame
        window = 0
        
        if turboActive and frameRate < 35 then
            -- we have most likely caught up
            disableCatchupMode()
        end
        if not turboActive and frameRate > 50 then
            -- we are probably catching up
            catchupMode()
        end
    end
    
end

function widget:GameProgress(frame)
    serverFrame = frame
    -- Spring.Echo("Server frame: " .. serverFrame)

    local behindFrames = serverFrame - spGetGameFrame()
    if behindFrames > CATCH_UP_THRESHOLD and not turboActive then
        catchupMode()
    end
    -- Spring.Echo("Frames behind server: " .. behindFrames, "Turbo catchup active: " .. tostring(turboActive),
    -- "frames limit: " .. CATCH_UP_THRESHOLD)
    if behindFrames <= CATCH_UP_THRESHOLD and turboActive then
        disableCatchupMode()
    end
end

function widget:Initialize()
    -- prefill the frames
    lastFrame = spGetGameFrame()
    frameRate = 30
    serverFrame = spGetGameFrame()

    WG['turbo_catchup'] = {
        RegisterWidget = function(widgetName)
            widgetWhitelist[widgetName] = true
        end,
        UnregisterWidget = function(widgetName)
            widgetWhitelist[widgetName] = nil
        end,
    }
end

function widget:Shutdown()
    WG['turbo_catchup'] = nil
end
