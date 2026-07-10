local widget = widget ---@type Widget

function widget:GetInfo()
    return {
        name = "Build Category Cycle Keys",
        desc = "Z/X/C/V cycle through the selected builder's Economy/Combat/Utility/Production build options",
        author = "uBdead",
        date = "July 2026",
        license = "GNU GPL, v2 or later",
        layer = -1, -- must be below gridmenu (layer 0) so our gridmenu_key action handler runs first
        enabled = true,
        handler = true, -- get the real widgetHandler (actionHandler, knownWidgets) instead of the proxy
    }
end

local grid = VFS.Include("luaui/configs/gridmenu_config.lua")
local units = VFS.Include("luaui/configs/unit_buildmenu_config.lua")

-- verbose tracing for debugging; echoes on every handled press
local DEBUG = false

local function dbg(fmt, ...)
    if DEBUG then
        Spring.Echo("[buildcycle] " .. string.format(fmt, ...))
    end
end

local function unitDefName(uDefID)
    local unitDef = uDefID and UnitDefs[uDefID]
    return unitDef and unitDef.name or tostring(uDefID)
end

-- category names must be the exact same I18N strings gridmenu_config.lua uses internally
local BUILDCAT_ECONOMY = Spring.I18N("ui.buildMenu.category_econ")
local BUILDCAT_COMBAT = Spring.I18N("ui.buildMenu.category_combat")
local BUILDCAT_UTILITY = Spring.I18N("ui.buildMenu.category_utility")
local BUILDCAT_PRODUCTION = Spring.I18N("ui.buildMenu.category_production")

-- index order matches both gridmenu's category order and the Z/X/C/V key order
---@type string[]
local categories = {
    BUILDCAT_ECONOMY,
    BUILDCAT_COMBAT,
    BUILDCAT_UTILITY,
    BUILDCAT_PRODUCTION,
}

-- SDL scancodes: the physical Z/X/C/V keys, independent of keyboard layout
local scancodeCategoryIndex = {
    [29] = 1, -- Z -> economy
    [27] = 2, -- X -> combat
    [6]  = 3, -- C -> utility
    [25] = 4, -- V -> production
}

local spGetActiveCommand = Spring.GetActiveCommand
local spSetActiveCommand = Spring.SetActiveCommand
local spGetCmdDescIndex = Spring.GetCmdDescIndex

-- the classic buildmenu (gui_buildmenu.lua) displays units in units.unitOrder sequence
local unitOrderRank = {}
for rank, unitDefID in ipairs(units.unitOrder) do
    unitOrderRank[unitDefID] = rank
end

-- mobile builders only; factories use a queue instead of categories
local isMobileBuilder = {}
for unitDefID, unitDef in pairs(UnitDefs) do
    if unitDef.isBuilder and not unitDef.isFactory and unitDef.buildOptions and #unitDef.buildOptions > 0 then
        isMobileBuilder[unitDefID] = true
    end
end

local isPregame = Spring.GetGameFrame() == 0 and not Spring.GetSpectatingState()

-- our own cycle cursor, used when the active command can't be matched back to the options list
local lastCategory, lastIndex

-- gridmenu's Shutdown leaves WG["gridmenu"] populated with dead closures, so the WG
-- table alone can't tell us whether the grid menu is the menu currently in use
---@return boolean
local function gridmenuIsActive()
    ---@type table<string, {active: boolean}>|nil
    local knownWidgets = widgetHandler.knownWidgets
    local known = knownWidgets and knownWidgets["Grid menu"]
    return (known and known.active and WG["gridmenu"] ~= nil) or false
end

local function getActiveBuilder()
    if isPregame then
        return Spring.GetTeamRulesParam(Spring.GetMyTeamID(), "startUnit")
    end

    -- follow whichever builder's grid the gridmenu is currently showing
    if gridmenuIsActive() and WG["gridmenu"].getActiveBuilder then
        local builderDefID = WG["gridmenu"].getActiveBuilder()
        return (builderDefID and isMobileBuilder[builderDefID]) and builderDefID or nil
    end

    -- fallback: lowest builder unitDefID in the selection, same as gridmenu's default
    local lowestDefID
    for unitDefID in pairs(Spring.GetSelectedUnitsSorted()) do
        if isMobileBuilder[unitDefID] and (not lowestDefID or unitDefID < lowestDefID) then
            lowestDefID = unitDefID
        end
    end
    return lowestDefID
end

-- category membership always comes from gridmenu_config; only the ordering depends
-- on which menu is visible (grid position order vs buildmenu's unitOrder)
local function getCategoryOptions(builderDefID, category)
    local buildOptions = UnitDefs[builderDefID].buildOptions
    local gridOpts = grid.getSortedGridForBuilder(builderDefID, buildOptions, category)
    if not gridOpts then
        return {}
    end

    local indices = {}
    for index in pairs(gridOpts) do
        indices[#indices + 1] = index
    end
    table.sort(indices)

    local options = {}
    local seen = {}
    for i = 1, #indices do
        local uDefID = -gridOpts[indices[i]].id
        if not seen[uDefID] then
            seen[uDefID] = true
            options[#options + 1] = uDefID
        end
    end

    if not gridmenuIsActive() then
        table.sort(options, function(a, b)
            return unitOrderRank[a] < unitOrderRank[b]
        end)
    end

    return options
end

local function getActiveBuildDefID()
    if isPregame then
        return WG["pregame-build"] and WG["pregame-build"].getPreGameDefID and WG["pregame-build"].getPreGameDefID()
    end

    local _, activeCmdID = spGetActiveCommand()
    return (activeCmdID and activeCmdID < 0) and -activeCmdID or nil
end

local function setActiveBuildDefID(uDefID)
    if isPregame then
        if WG["pregame-build"] and WG["pregame-build"].setPreGamestartDefID then
            WG["pregame-build"].setPreGamestartDefID(uDefID)
            return true
        end
        return false
    end

    local cmdIndex = spGetCmdDescIndex(-uDefID)
    return (cmdIndex and spSetActiveCommand(cmdIndex)) or false
end

-- returns true when the keypress was handled (a mobile builder is selected)
local function cycleCategory(category)
    if Spring.GetSpectatingState() then
        return false
    end

    local builderDefID = getActiveBuilder()
    if not builderDefID then
        return false
    end

    local options = getCategoryOptions(builderDefID, category)
    if #options == 0 then
        return true
    end

    -- resume from the currently active build command; must be read before
    -- setCurrentCategory since gridmenu may auto-select the category's first option
    local currentIndex = 0
    local activeDefID = getActiveBuildDefID()
    if activeDefID then
        for i = 1, #options do
            if options[i] == activeDefID then
                currentIndex = i
                break
            end
        end
        -- other widgets can swap the blueprint for a custom command (e.g. area mex);
        -- fall back to our own cursor so the cycle doesn't reset or bounce
        if currentIndex == 0 and category == lastCategory and lastIndex then
            currentIndex = math.min(lastIndex, #options)
            dbg("read-back miss, cursor fallback to %d", currentIndex)
        end
    end

    if DEBUG then
        local names = {}
        for i = 1, #options do
            names[i] = (i == currentIndex and "*" or "") .. unitDefName(options[i])
        end
        dbg("builder=%s cat=%s active=%s matched=%d last=%s/%s gridmenu=%s opts=[%s]",
            unitDefName(builderDefID), category, unitDefName(activeDefID), currentIndex,
            tostring(lastCategory), tostring(lastIndex), tostring(gridmenuIsActive()),
            table.concat(names, " "))
    end

    -- make the grid menu UI follow along
    if gridmenuIsActive() and WG["gridmenu"].setCurrentCategory then
        WG["gridmenu"].setCurrentCategory(category)
    end

    -- advance to the next option, skipping any that can't be selected (restricted units etc)
    for step = 1, #options do
        local index = (currentIndex + step - 1) % #options + 1
        if setActiveBuildDefID(options[index]) then
            dbg("set #%d %s (attempt %d)", index, unitDefName(options[index]), step)
            lastCategory = category
            lastIndex = index
            break
        else
            dbg("FAILED to set #%d %s (cmdDescIndex=%s)", index, unitDefName(options[index]),
                tostring(spGetCmdDescIndex(-options[index])))
        end
    end

    return true
end

-- With grid keybinds, Z/X/C/V are bound to "gridmenu_key 1 <col>" and bound actions are
-- dispatched before any widget:KeyPress (see widgetHandler:KeyPress in barwidgets.lua),
-- so gridmenu would consume the keys once a category is open. We register the same
-- action at a lower layer, take over the bottom row for mobile builders, and let
-- everything else (factories, qwer/asdf rows) fall through to gridmenu.
local function gridKeyActionHandler(_, _, words, _, isRepeat)
    local row = words and tonumber(words[1])
    local col = words and tonumber(words[2])

    if row ~= 1 or not col or col < 1 or col > 4 then
        return false
    end

    if Spring.GetSpectatingState() then
        return false
    end

    if not getActiveBuilder() then
        return false
    end

    if isRepeat then
        return true -- swallow repeats so gridmenu doesn't pick the bottom-row cell
    end

    local alt, ctrl, meta = Spring.GetModKeyState()
    if alt or ctrl or meta then
        return false
    end

    dbg("entry: gridmenu_key action row=%s col=%s", tostring(row), tostring(col))
    return cycleCategory(categories[col])
end

-- fallback for setups where Z/X/C/V are not bound to gridmenu_key actions
-- (e.g. the classic buildmenu is enabled, or non-grid keybind layouts)
function widget:KeyPress(_keyCode, mods, isRepeat, _label, _utf32char, scanCode)
    if isRepeat or mods.alt or mods.ctrl or mods.meta then
        return false
    end

    local categoryIndex = scancodeCategoryIndex[scanCode]
    if not categoryIndex then
        return false
    end

    if Spring.IsUserWriting() then
        return false
    end

    dbg("entry: KeyPress scancode=%d", scanCode)
    return cycleCategory(categories[categoryIndex])
end

function widget:SelectionChanged()
    lastCategory, lastIndex = nil, nil
end

function widget:GameStart()
    isPregame = false
end

-- Context Build silently swaps blueprints for their land/water counterparts (e.g.
-- corfrad -> corrad), which re-anchors our cycle and breaks it for amphibious
-- builders like the commander; only re-enable it on shutdown if it was us who
-- disabled it
local reEnableContextBuild = false
local checkedContextBuild = false

local function disableContextBuild()
    ---@type table<string, {active: boolean}>|nil
    local knownWidgets = widgetHandler.knownWidgets
    local contextBuild = knownWidgets and knownWidgets["Context Build"]
    if contextBuild and contextBuild.active then
        widgetHandler:DisableWidgetRaw("Context Build")
        reEnableContextBuild = true
    end
end

function widget:Initialize()
    widgetHandler.actionHandler:AddAction(self, "gridmenu_key", gridKeyActionHandler, nil, "pR")

    if DEBUG then
        for _, key in ipairs({ "sc_z", "sc_x", "sc_c", "sc_v" }) do
            local ok, bindings = pcall(Spring.GetKeyBindings, key)
            if ok and bindings then
                for _, kb in ipairs(bindings) do
                    dbg("bind %s -> %s %s", key, kb.command or "?", kb.extra or "")
                end
            end
        end
    end

    -- catches Context Build when this widget is (re)loaded mid-game
    disableContextBuild()
end

-- Context Build has layer 1, ours is -1, so on a full LuaUI load it initializes
-- after us and Initialize can't see it yet; check once more when all widgets are up
function widget:Update()
    if not checkedContextBuild then
        checkedContextBuild = true
        disableContextBuild()
        if reEnableContextBuild then
            dbg("disabled Context Build on first Update")
        end
    end
end

function widget:Shutdown()
    widgetHandler.actionHandler:RemoveAction(self, "gridmenu_key", "pR")

    if reEnableContextBuild then
        reEnableContextBuild = false
        widgetHandler:EnableWidgetRaw("Context Build")
    end
end
