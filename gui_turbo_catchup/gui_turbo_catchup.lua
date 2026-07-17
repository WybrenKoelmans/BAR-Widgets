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

local LOCK_DIR = "LuaUI/Config"
local LOCK_FILE = LOCK_DIR .. "/turbo_catchup_lock.lua"

-- The lock file is our crash-recovery record: it always reflects (a superset of)
-- whatever is currently force-disabled. If this widget errors out, or the whole
-- game crashes, mid-catchup, the in-memory disabledWidgets table is lost, but the
-- file on disk survives and lets widget:Initialize() restore everything next time.
local function writeLockFile(widgets)
    local ok, err = pcall(function()
        Spring.CreateDir(LOCK_DIR)
        table.save(widgets, LOCK_FILE, "-- Turbo Catchup lock file, auto-restored on next widget init")
    end)
    if not ok then
        Spring.Echo("Turbo Catchup: failed to write lock file: " .. tostring(err))
    end
end

local function clearLockFile()
    if VFS.FileExists(LOCK_FILE) then
        pcall(os.remove, LOCK_FILE)
    end
end

local function readLockFile()
    if not VFS.FileExists(LOCK_FILE) then
        return nil
    end
    local ok, result = pcall(VFS.Include, LOCK_FILE)
    if not ok or type(result) ~= "table" then
        Spring.Echo("Turbo Catchup: lock file present but unreadable, discarding it: " .. tostring(result))
        return nil
    end
    return result
end

-- Restore any widgets that a previous session left disabled without ever
-- getting to call disableCatchupMode (widget error, forced quit, engine crash).
local function restoreFromLockFile()
    local stale = readLockFile()
    if not stale or not next(stale) then
        clearLockFile()
        return
    end

    Spring.Echo("Turbo Catchup: found a leftover lock file from a previous session, restoring widgets disabled by it")
    for name in pairs(stale) do
        if not widgetWhitelist[name] then
            local ok, err = pcall(function() widgetHandler:EnableWidget(name) end)
            if not ok then
                Spring.Echo("Turbo Catchup: failed to restore widget '" .. tostring(name) .. "': " .. tostring(err))
            end
        end
    end
    clearLockFile()
end

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

    -- Work out the full set of widgets we're about to disable before touching
    -- any of them, and persist it immediately. If we crash partway through the
    -- disabling loop below, the lock file already lists everything we intended
    -- to disable, so recovery on the next Initialize is never missing an entry.
    local toDisable = {}
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
            toDisable[name] = true
        end
    end

    writeLockFile(toDisable)

    for name in pairs(toDisable) do
        local ok, err = pcall(function() widgetHandler:DisableWidget(name) end)
        if ok then
            disabledWidgets[name] = true
        else
            Spring.Echo("Turbo Catchup: failed to disable widget '" .. tostring(name) .. "': " .. tostring(err))
        end
    end
end

local function disableCatchupMode()
    if not turboActive then return end -- not in catchup mode, no need to do anything

    -- disable catchup mode
    turboActive = false
    Spring.Echo("Disabling turbo catchup mode, caught up to server")
    for name in pairs(disabledWidgets) do
        if not widgetWhitelist[name] then
            local ok, err = pcall(function() widgetHandler:EnableWidget(name) end)
            if ok then
                disabledWidgets[name] = nil
            else
                Spring.Echo("Turbo Catchup: failed to re-enable widget '" .. tostring(name) .. "': " .. tostring(err))
            end
        else
            disabledWidgets[name] = nil
        end
    end

    -- Only clear the lock file once everything has actually been restored;
    -- otherwise keep it (updated) so a future Initialize can retry the rest.
    if not next(disabledWidgets) then
        clearLockFile()
    else
        writeLockFile(disabledWidgets)
    end
end

function widget:Update(dt)
    local currentFrame = spGetGameFrame()

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

    local behindFrames = serverFrame - spGetGameFrame()
    if behindFrames > CATCH_UP_THRESHOLD and not turboActive then
        catchupMode()
    end
    if behindFrames <= CATCH_UP_THRESHOLD and turboActive then
        disableCatchupMode()
    end
end

function widget:Initialize()
    if Spring.IsReplay() then
        Spring.Echo("Turbo Catchup: Replay detected, disabling widget")
        widgetHandler:RemoveWidget()
        return
    end

    -- prefill the frames
    lastFrame = spGetGameFrame()
    frameRate = 30
    serverFrame = spGetGameFrame()

    -- If a previous session crashed (or was otherwise torn down) while widgets
    -- were force-disabled, restore them now before doing anything else.
    restoreFromLockFile()

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
