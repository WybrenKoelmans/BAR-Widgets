-- luacheck: globals widget RmlUi
if not RmlUi then
    return
end

local widget = widget ---@type Widget

function widget:GetInfo()
    return {
        name = "Widget Presets",
        desc = "Stores and applies presets of widget states, with automatic mode switching for Player/Spectator/Replay.",
        author = "uBdead",
        date = "2026-04-10",
        license = "GNU GPL, v2 or later",
        layer = 0,
        enabled = true,
        handler = true,
    }
end

------------------------------------------------------------------------
-- Constants
------------------------------------------------------------------------
local WIDGET_NAME = "gui_widgets_presets"
local MODEL_NAME = "widget_presets_model"
local RML_PATH = "LuaUI/Widgets/gui_widgets_presets/gui_widgets_presets.rml"
local PRESETS_FILE = "LuaUI/Config/WidgetPresets.lua"

------------------------------------------------------------------------
-- Spring API caching
------------------------------------------------------------------------
local spIsReplay = Spring.IsReplay
local spGetSpectatingState = Spring.GetSpectatingState
local spGetGameFrame = Spring.GetGameFrame
local spSetConfigInt = Spring.SetConfigInt
local spGetConfigInt = Spring.GetConfigInt
local spGetViewGeometry = Spring.GetViewGeometry
local spEcho = Spring.Echo

------------------------------------------------------------------------
-- Widget state
------------------------------------------------------------------------
local document
local notifyDocument
local dm_handle
local panelVisible = false
local openedViaSelector = false  -- track how panel was opened
local statusTimer = 0

local NOTIFY_RML_PATH = "LuaUI/Widgets/gui_widgets_presets/gui_widgets_presets_notify.rml"

------------------------------------------------------------------------
-- Helper: check if a widget is a user (non-zip) widget
------------------------------------------------------------------------
local function IsUserWidget(name)
    local ki = widgetHandler.knownWidgets[name]
    return ki and not ki.fromZip
end

-- Preset data structure
-- presets = {
--     ["Name"] = {
--         widgets = { ["Widget Name"] = true, ... },
--         isUserPreset = true/false,
--     },
-- }
------------------------------------------------------------------------
local presets = {}

-- Auto-switch configuration
local autoSwitch = {
    player = "",
    spectator = "",
    replay = "",
}

local lastGameState = ""
local bannerDismissedForState = ""

------------------------------------------------------------------------
-- Persistence
------------------------------------------------------------------------
local function SavePresets()
    local saveData = {
        presets = {},
        autoSwitch = autoSwitch,
    }
    for name, preset in pairs(presets) do
        saveData.presets[name] = {
            widgets = preset.widgets,
        }
    end
    table.save(saveData, PRESETS_FILE, "-- Widget Presets Configuration")
end

local function LoadPresets()
    local chunk, err = loadfile(PRESETS_FILE)
    if chunk then
        local data = chunk()
        if data then
            if data.presets then
                for name, preset in pairs(data.presets) do
                    presets[name] = {
                        widgets = preset.widgets or {},
                        isUserPreset = true,
                    }
                end
            end
            if data.autoSwitch then
                autoSwitch.player = data.autoSwitch.player or ""
                autoSwitch.spectator = data.autoSwitch.spectator or ""
                autoSwitch.replay = data.autoSwitch.replay or ""
            end
        end
    end
end

------------------------------------------------------------------------
-- Game State Detection
------------------------------------------------------------------------
local function GetGameState()
    if spIsReplay() then
        return "replay"
    end
    local spectating = spGetSpectatingState()
    if spectating then
        return "spectator"
    end
    return "player"
end

local function GetGameStateLabel(state)
    if state == "replay" then return "Replay"
    elseif state == "spectator" then return "Spectator"
    else return "Player"
    end
end

------------------------------------------------------------------------
-- Widget State Helpers
------------------------------------------------------------------------
local function GetWidgetToggleValue(widgetname)
    if widgetHandler.orderList[widgetname] == nil or widgetHandler.orderList[widgetname] == 0 then
        return false
    elseif widgetHandler.orderList[widgetname] >= 1
        and widgetHandler.knownWidgets ~= nil
        and widgetHandler.knownWidgets[widgetname] ~= nil then
        if widgetHandler.knownWidgets[widgetname].active then
            return true
        else
            return 0.5  -- errored
        end
    end
    return false
end

local function GetCurrentActiveWidgets()
    local active = {}
    for name, _ in pairs(widgetHandler.knownWidgets) do
        if IsUserWidget(name) then
            local state = GetWidgetToggleValue(name)
            if state == true then
                active[name] = true
            end
        end
    end
    return active
end

local function CountTable(t)
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    return count
end

local function CalculateMatchPercent(presetWidgets)
    local currentActive = GetCurrentActiveWidgets()
    local presetCount = CountTable(presetWidgets)
    local currentCount = CountTable(currentActive)

    if presetCount == 0 and currentCount == 0 then return 100 end
    if presetCount == 0 then return 0 end

    -- Calculate symmetric match: how similar are the two sets?
    local matches = 0
    local total = 0
    local seen = {}

    for name in pairs(presetWidgets) do
        seen[name] = true
        total = total + 1
        if currentActive[name] then
            matches = matches + 1
        end
    end
    for name in pairs(currentActive) do
        if not seen[name] then
            total = total + 1
        end
    end

    if total == 0 then return 100 end
    return math.floor((matches / total) * 100)
end

------------------------------------------------------------------------
-- Applying Presets
------------------------------------------------------------------------
local widgetsToProtect = {
    ["Widget Presets"] = true,
}

local function ApplyPreset(presetName)
    local preset = presets[presetName]
    if not preset then
        spEcho("Widget Presets: Preset not found: " .. tostring(presetName))
        return false
    end

    local target = preset.widgets
    local currentActive = GetCurrentActiveWidgets()

    -- Disable widgets that are active but not in the target preset
    for name in pairs(currentActive) do
        if not target[name] and not widgetsToProtect[name] then
            widgetHandler:DisableWidget(name)
        end
    end

    -- Enable widgets that are in the target but not currently active
    for name in pairs(target) do
        if not currentActive[name] and not widgetsToProtect[name] then
            widgetHandler:EnableWidget(name)
        end
    end

    spEcho("Widget Presets: Applied preset '" .. presetName .. "'")
    return true
end

------------------------------------------------------------------------
-- Data Model Helpers (update the RML-bound model)
------------------------------------------------------------------------
local function BuildPresetListForModel()
    local list = {}
    local sorted = {}
    for name in pairs(presets) do
        table.insert(sorted, name)
    end
    table.sort(sorted)
    for _, name in ipairs(sorted) do
        local preset = presets[name]
        local matchPct = CalculateMatchPercent(preset.widgets)
        table.insert(list, {
            name = name,
            widgetCount = CountTable(preset.widgets),
            matchPercent = matchPct,
            isUserPreset = 1,
        })
    end
    return list
end

local function FindActivePresetName()
    for name, preset in pairs(presets) do
        if CalculateMatchPercent(preset.widgets) == 100 then
            return name
        end
    end
    return ""
end

local function RefreshModel()
    if not dm_handle then return end
    dm_handle.presets = BuildPresetListForModel()
    dm_handle.activePresetName = FindActivePresetName()
    local state = GetGameState()
    dm_handle.gameState = state
    dm_handle.gameStateLabel = GetGameStateLabel(state)
    dm_handle.autoPlayerPreset = autoSwitch.player
    dm_handle.autoSpectatorPreset = autoSwitch.spectator
    dm_handle.autoReplayPreset = autoSwitch.replay
end

local function SetStatus(msg)
    if dm_handle then
        dm_handle.statusMessage = msg
        statusTimer = 3 -- seconds to display
    end
end

------------------------------------------------------------------------
-- Auto-switch and state change banner logic
------------------------------------------------------------------------
local function GetSuggestedPreset(state)
    if state == "player" and autoSwitch.player ~= "" then
        return autoSwitch.player
    elseif state == "spectator" and autoSwitch.spectator ~= "" then
        return autoSwitch.spectator
    elseif state == "replay" and autoSwitch.replay ~= "" then
        return autoSwitch.replay
    end
    return ""
end

local function CheckStateChange()
    local state = GetGameState()
    if state ~= lastGameState then
        local oldState = lastGameState
        lastGameState = state

        if dm_handle then
            dm_handle.gameState = state
            dm_handle.gameStateLabel = GetGameStateLabel(state)
        end

        if oldState ~= "" then -- not initial detection
            local suggested = GetSuggestedPreset(state)
            if suggested ~= "" and presets[suggested] then
                -- Auto-switch is configured: apply immediately
                if CalculateMatchPercent(presets[suggested].widgets) == 100 then
                    return -- Already matching
                end
                ApplyPreset(suggested)
                SetStatus("Auto-switched to: " .. suggested)
                RefreshModel()
                spEcho("Widget Presets: Auto-switched to '" .. suggested
                    .. "' (" .. GetGameStateLabel(state) .. ")")
            else
                -- No auto-switch configured: show floating notify button
                if dm_handle then
                    dm_handle.showStateChangeBanner = 1
                    dm_handle.suggestedPreset = ""
                    bannerDismissedForState = ""
                end
                widget:ShowNotify()
                spEcho("Widget Presets: Game state changed to " .. GetGameStateLabel(state))
            end
        end
    end
end

------------------------------------------------------------------------
-- RML Data Model Init
------------------------------------------------------------------------
local init_model = {
    -- State
    presets = {},
    activePresetName = "",
    gameState = "player",
    gameStateLabel = "Player",
    newPresetName = "",
    statusMessage = "",

    -- State change banner
    showStateChangeBanner = 0,
    suggestedPreset = "",

    -- Auto-switch settings
    autoPlayerPreset = "",
    autoSpectatorPreset = "",
    autoReplayPreset = "",

    -- Actions
    loadPreset = function(ev, presetName)
        if ApplyPreset(presetName) then
            SetStatus("Loaded preset: " .. presetName)
            RefreshModel()
        else
            SetStatus("Failed to load preset: " .. presetName)
        end
    end,

    saveNewPreset = function(ev, name)
        if (not name or name == "") and dm_handle then
            name = dm_handle.newPresetName
        end
        if not name or name == "" then
            SetStatus("Enter a preset name first")
            return
        end
        -- Sanitize: only allow alphanumeric, spaces, dashes, underscores
        if string.find(name, "[^%w%s%-_]") then
            SetStatus("Invalid name: use letters, numbers, spaces, dashes")
            return
        end
        presets[name] = {
            widgets = GetCurrentActiveWidgets(),
            isUserPreset = true,
        }
        SavePresets()
        dm_handle.newPresetName = ""
        SetStatus("Saved preset: " .. name)
        RefreshModel()
    end,

    updatePreset = function(ev, presetName)
        if not presetName then
            SetStatus("Cannot update preset")
            return
        end
        if presets[presetName] and presets[presetName].isUserPreset then
            presets[presetName].widgets = GetCurrentActiveWidgets()
            SavePresets()
            SetStatus("Updated preset: " .. presetName)
            RefreshModel()
        end
    end,

    deletePreset = function(ev, presetName)
        if not presetName then
            SetStatus("Cannot delete preset")
            return
        end
        if presets[presetName] then
            presets[presetName] = nil
            -- Clear auto-switch references
            if autoSwitch.player == presetName then autoSwitch.player = "" end
            if autoSwitch.spectator == presetName then autoSwitch.spectator = "" end
            if autoSwitch.replay == presetName then autoSwitch.replay = "" end
            SavePresets()
            SetStatus("Deleted preset: " .. presetName)
            RefreshModel()
        end
    end,

    savePlayerPreset = function(ev)
        autoSwitch.player = ev.parameters.value
        dm_handle.autoPlayerPreset = autoSwitch.player
        SavePresets()
        SetStatus("Auto-switch saved")
    end,

    saveSpectatorPreset = function(ev)
        autoSwitch.spectator = ev.parameters.value
        dm_handle.autoSpectatorPreset = autoSwitch.spectator
        SavePresets()
        SetStatus("Auto-switch saved")
    end,

    saveReplayPreset = function(ev)
        autoSwitch.replay = ev.parameters.value
        dm_handle.autoReplayPreset = autoSwitch.replay
        SavePresets()
        SetStatus("Auto-switch saved")
    end,

    applySuggestedPreset = function()
        if not dm_handle then return end
        local suggested = dm_handle.suggestedPreset
        if suggested and suggested ~= "" then
            ApplyPreset(suggested)
            dm_handle.showStateChangeBanner = 0
            SetStatus("Switched to: " .. suggested)
            RefreshModel()
        end
    end,

    openPanel = function()
        widget:ShowPanelIndependent()
    end,

    dismissBanner = function()
        if dm_handle then
            dm_handle.showStateChangeBanner = 0
            bannerDismissedForState = lastGameState
        end
        widget:HideNotify()
    end,

    closePanel = function()
        widget:HidePanel()
    end,
}

------------------------------------------------------------------------
-- Notify Visibility
------------------------------------------------------------------------
function widget:ShowNotify()
    if not notifyDocument then return end
    notifyDocument:Show()
end

function widget:HideNotify()
    if not notifyDocument then return end
    notifyDocument:Hide()
end

------------------------------------------------------------------------
-- Panel Visibility
------------------------------------------------------------------------
function widget:ShowPanel()
    if not document then return end
    panelVisible = true
    widget:HideNotify()
    if dm_handle then dm_handle.showStateChangeBanner = 0 end
    RefreshModel()
    document:Show()
end

function widget:ShowPanelFromSelector()
    openedViaSelector = true
    widget:ShowPanel()
end

function widget:ShowPanelIndependent()
    openedViaSelector = false
    widget:ShowPanel()
end

function widget:HidePanel()
    if not document then return end
    panelVisible = false
    document:Hide()
end

function widget:TogglePanel()
    if panelVisible then
        widget:HidePanel()
    else
        widget:ShowPanelIndependent()
    end
end

------------------------------------------------------------------------
-- Widget Lifecycle
------------------------------------------------------------------------
function widget:Initialize()
    if not RmlUi then
        widgetHandler:RemoveWidget()
        return
    end

    -- Load user presets from disk
    LoadPresets()

    -- Detect initial game state
    lastGameState = GetGameState()

    -- Setup RmlUI
    widget.rmlContext = RmlUi.GetContext("shared")
    if not widget.rmlContext then
        spEcho("Widget Presets: Failed to get shared RML context")
        widgetHandler:RemoveWidget()
        return
    end

    -- Set initial model values from loaded state
    init_model.gameState = lastGameState
    init_model.gameStateLabel = GetGameStateLabel(lastGameState)
    init_model.autoPlayerPreset = autoSwitch.player
    init_model.autoSpectatorPreset = autoSwitch.spectator
    init_model.autoReplayPreset = autoSwitch.replay
    init_model.presets = BuildPresetListForModel()
    init_model.activePresetName = FindActivePresetName()

    dm_handle = widget.rmlContext:OpenDataModel(MODEL_NAME, init_model)
    if not dm_handle then
        spEcho("Widget Presets: Failed to create data model")
        widgetHandler:RemoveWidget()
        return
    end

    document = widget.rmlContext:LoadDocument(RML_PATH, widget)
    if not document then
        spEcho("Widget Presets: Failed to load RML document")
        widget:Shutdown()
        widgetHandler:RemoveWidget()
        return
    end

    document:AddEventListener("dragend", function() widget:SavePosition() end)
    document:ReloadStyleSheet()

    -- Start hidden; shown via widget selector integration or keybind
    document:Hide()
    panelVisible = false

    widget:LoadPosition()

    -- Load floating notify document (shares same data model)
    notifyDocument = widget.rmlContext:LoadDocument(NOTIFY_RML_PATH, widget)
    if notifyDocument then
        notifyDocument:ReloadStyleSheet()
        notifyDocument:Hide()
    end

    -- Expose WG API for other widgets
    WG['widget_presets'] = {
        show = function() widget:ShowPanel() end,
        hide = function() widget:HidePanel() end,
        toggle = function() widget:TogglePanel() end,
        isvisible = function() return panelVisible end,
        getPresetNames = function()
            local names = {}
            for name in pairs(presets) do
                table.insert(names, name)
            end
            table.sort(names)
            return names
        end,
        applyPreset = function(name) return ApplyPreset(name) end,
    }

    -- Apply auto-switch preset for initial game state
    local initialPreset = GetSuggestedPreset(lastGameState)
    if initialPreset ~= "" and presets[initialPreset] then
        if CalculateMatchPercent(presets[initialPreset].widgets) ~= 100 then
            ApplyPreset(initialPreset)
            RefreshModel()
            spEcho("Widget Presets: Auto-applied preset '" .. initialPreset
                .. "' for " .. GetGameStateLabel(lastGameState) .. " mode")
        end
    end

    spEcho("Widget Presets: Initialized (" .. GetGameStateLabel(lastGameState) .. " mode)")
end

function widget:Shutdown()
    WG['widget_presets'] = nil

    if widget.rmlContext and dm_handle then
        widget.rmlContext:RemoveDataModel(MODEL_NAME)
        dm_handle = nil
    end

    if document then
        document:Close()
        document = nil
    end

    if notifyDocument then
        notifyDocument:Close()
        notifyDocument = nil
    end

    widget.rmlContext = nil
end

------------------------------------------------------------------------
-- Position Persistence
------------------------------------------------------------------------
function widget:SavePosition()
    if not document then return end
    local element = document:GetElementById("widget-presets-widget")
    if not element then return end
    local x = element.offset_left
    local y = element.offset_top
    if not x or not y then return end

    local vsx, vsy = spGetViewGeometry()
    if not vsx or not vsy then return end
    local relX = x / vsx
    local relY = y / vsy
    spSetConfigInt("widget_presets_RelX", math.floor(relX * 1000))
    spSetConfigInt("widget_presets_RelY", math.floor(relY * 1000))
end

function widget:LoadPosition()
    if not document then return end
    local element = document:GetElementById("widget-presets-widget")
    if not element then return end
    local relX = spGetConfigInt("widget_presets_RelX", -1)
    local relY = spGetConfigInt("widget_presets_RelY", -1)
    if relX == -1 or relY == -1 then return end
    relX = relX / 1000
    relY = relY / 1000
    local vsx, vsy = spGetViewGeometry()
    if not vsx or not vsy then return end
    local x = math.floor(relX * vsx)
    local y = math.floor(relY * vsy)
    element.style.position = "absolute"
    element.style.left = x .. "dp"
    element.style.top = y .. "dp"
end

------------------------------------------------------------------------
-- Update Loop
------------------------------------------------------------------------
local refreshTimer = 0
local REFRESH_INTERVAL = 2 -- seconds between match% recalculation

function widget:Update(dt)
    -- State change detection
    CheckStateChange()

    -- Status message timer
    if statusTimer > 0 then
        statusTimer = statusTimer - dt
        if statusTimer <= 0 then
            statusTimer = 0
            if dm_handle then
                dm_handle.statusMessage = ""
            end
        end
    end

    -- Periodic refresh of match percentages (only when panel visible)
    if panelVisible then
        refreshTimer = refreshTimer + dt
        if refreshTimer >= REFRESH_INTERVAL then
            refreshTimer = 0
            RefreshModel()
        end
    end

    -- Sync visibility with the widget selector
    local selectorOpen = WG['widgetselector'] ~= nil and WG['widgetselector'].isvisible()
    if not panelVisible and selectorOpen then
        widget:ShowPanelFromSelector()
    elseif panelVisible and openedViaSelector and not selectorOpen then
        widget:HidePanel()
    end
end

------------------------------------------------------------------------
-- Player changed callback (handles player -> spectator transitions)
------------------------------------------------------------------------
function widget:PlayerChanged(playerID)
    CheckStateChange()
end

------------------------------------------------------------------------
-- Keybind support: can be bound via /bind key widget_presets_toggle
------------------------------------------------------------------------
function widget:TextCommand(command)
    if command == "widget_presets_toggle" then
        widget:TogglePanel()
        return true
    end
    if command == "widget_presets_show" then
        widget:ShowPanel()
        return true
    end
    if command == "widget_presets_hide" then
        widget:HidePanel()
        return true
    end
    return false
end
