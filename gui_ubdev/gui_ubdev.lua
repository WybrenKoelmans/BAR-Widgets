
-- luacheck: globals widget RmlUi CMD ---@type Widget
if not RmlUi then
    return
end

-- Cache Spring.* and CMD.* as local variables for optimization
local spGetAIInfo = Spring.GetAIInfo
local spGetGameRulesParam = Spring.GetGameRulesParam
local spUtilitiesShowDevUI = Spring.Utilities and Spring.Utilities.ShowDevUI
local spI18N = Spring.I18N
local spGetTeamList = Spring.GetTeamList
local spGetTeamInfo = Spring.GetTeamInfo
local spGetPlayerInfo = Spring.GetPlayerInfo
local spGetMyTeamID = Spring.GetMyTeamID
local spGetViewGeometry = Spring.GetViewGeometry
local spSetConfigInt = Spring.SetConfigInt
local spGetConfigInt = Spring.GetConfigInt
local spGetMouseState = Spring.GetMouseState
local spTraceScreenRay = Spring.TraceScreenRay
local spSendCommands = Spring.SendCommands
local spGiveOrderToUnit = Spring.GiveOrderToUnit
local spGetTeamUnits = Spring.GetTeamUnits
local spGetUnitStates = Spring.GetUnitStates

local CMD_WAIT = CMD and CMD.WAIT

local widget = widget ---@type Widget

function widget:GetInfo()
    return {
        name = "uBdev Tools",
        desc = "The ultimate dev toolkit",
        author = "uBdead",
        date = "2025-10-20",
        license = "GNU GPL, v2 or later",
        layer = 0,
        enabled = true,
    }
end

-- Constants
local WIDGET_NAME = "gui_ubdev"
local MODEL_NAME = "gui_ubdev_model"
local RML_PATH = "LuaUI/Widgets/gui_ubdev/gui_ubdev.rml"

-- Widget state
local document
local dm_handle
local arePausing = true
local drawHandle = nil
-- Load icontypes table from BAR.sdd/gamedata/icontypes.lua
local icontypes = VFS.Include("gamedata/icontypes.lua")


local function GetFaction(unitdef)
    local name = unitdef.name
    if string.find(name, "_scav") then
        return ''
    elseif string.sub(name, 1, 3) == "arm" then
        return 'arm'
    elseif string.sub(name, 1, 3) == "cor" then
        return 'cor'
    elseif string.sub(name, 1, 3) == "leg" then
        return 'leg'
    elseif string.find(name, 'raptor') then
        return ''
    end
    return ''
end

local favoriteUnitsNames = {
    resourcecheat = true,
    correspawn = true,
    armcom = true,
    corcom = true,
    legcom = true,
}
local favorites = {}
local nameToDefID = {}

local allUnits = {}
for _, unitDef in ipairs(UnitDefs) do
    local iconPath = "unitpics/" .. unitDef.name .. ".dds"

    -- check if the file exists
    if not VFS.FileExists(iconPath) then
        local iconType = unitDef and unitDef.iconType
        local iconName = iconType and icontypes[iconType] and icontypes[iconType].bitmap
        iconPath = iconName and ("/" .. iconName) or "/icons/inverted/blank.png"
    else
        iconPath = "/" .. iconPath
    end

    local group = unitDef.customParams and unitDef.customParams.unitgroup or 'weaponexplo'
    if group == 'explo' then -- who the f knows
        group = 'weaponexplo'
    end

    local def = {
        humanName = unitDef.translatedHumanName or unitDef.humanName or unitDef.name or "???",
        name = unitDef.name,
        imgPath = iconPath,
        techlevel = unitDef.customParams and tonumber(unitDef.customParams.techlevel) or 1,
        faction = GetFaction(unitDef),
        group = group,
        isMobile = unitDef.isBuilding and 0 or 1,
    }
    nameToDefID[unitDef.name] = unitDef.id

    if favoriteUnitsNames[unitDef.name] then
        table.insert(favorites, def)
    end

    table.insert(allUnits, def)
end
table.sort(allUnits, function(a, b)
    return a.humanName < b.humanName
end)

function GetAIName(teamID)
    local _, _, _, name, _, options = spGetAIInfo(teamID)
    local niceName = spGetGameRulesParam('ainame_' .. teamID)

    if niceName then
        name = niceName

        if spUtilitiesShowDevUI and spUtilitiesShowDevUI() and options.profile then
            name = name .. " [" .. options.profile .. "]"
        end
    end

    return spI18N('ui.playersList.aiName', { name = name })
end

local teamList = spGetTeamList()
local teams = {} -- id -> name
for _, teamID in ipairs(spGetTeamList()) do
    local id, leader, isDead, hasAI = spGetTeamInfo(teamID, false)
    local teamName = spGetPlayerInfo(leader, false)
    teams[teamID + 1] = hasAI and GetAIName(teamID) or teamName
end
for i = 1, #teamList do
    local id, leader, isDead, hasAI = spGetTeamInfo(teamList[i], false)
    local teamName = spGetPlayerInfo(leader, false)
    if teamName then
        teams[i] = {
            id = id,
            name = hasAI and GetAIName(teamList[i]) or teamName,
        }
    end
end

-- Initial data model
local init_model = {
    debugMode = false,
    units = allUnits,
    selectedUnit = '',
    unitsFilterText = '',
    unitsFilterTechLevel = 0,
    unitsFilterFaction = '',
    unitsFilterIsMobile = -1,
    selectedTeamID = spGetMyTeamID(),
    teams = teams,
    favorites = favorites,
    selectUnit = function(ev, unitName)
        dm_handle.selectedUnit = unitName
    end,
    filterUnits = function(ev, text, level, faction, isMobile)
        local filtered = {}
        local lowerFilter = string.lower(text or '')
        local techLevel = level or 0
        local faction = faction or ''
        local isMobile = isMobile or -1

        for _, unit in ipairs(allUnits) do
            if unit.faction == faction or faction == '' then
                if unit.techlevel == techLevel or techLevel == 0 then
                    if unit.isMobile == isMobile or isMobile == -1 then
                        if string.find(string.lower(unit.humanName), lowerFilter, 1, true) 
                        or string.find(string.lower(unit.name), lowerFilter, 1, true) then
                            table.insert(filtered, unit)
                        end
                    end
                end
            end
        end
        table.sort(filtered, function(a, b)
            return a.humanName < b.humanName
        end)
        dm_handle.units = filtered
    end,
    sendCommand = function(ev, command)
        widget:SendCommand(command)
    end,
    updateTeam = function(ev)
        dm_handle.selectedTeamID = ev.parameters.value
        widget:SendCommand("team " .. ev.parameters.value)
    end,
}

local function clearDrawHandles()
    if drawHandle then
        WG.StopDrawUnitShapeGL4(drawHandle)
        drawHandle = nil
    end
end

function widget:MousePress(x, y, button)
    if button == 3 then
        dm_handle.selectedUnit = ''
        clearDrawHandles()

        return false
    end

    if button == 2 then
        return false
    end

    if dm_handle.selectedUnit == '' then
        dm_handle.selectedUnit = ''
        clearDrawHandles()

        return false
    end

    local type, pos = Spring.TraceScreenRay(x, y)
    if type ~= 'ground' then
        return true
    end
    local wx, wy, wz = pos[1], pos[2], pos[3]

    local alt, ctrl, meta, shift = Spring.GetModKeyState()

    local amount = 1
    if ctrl then
        amount = amount * 5
    end
    if shift then
        amount = amount * 10
    end

    if wx and wy and wz then
        spSendCommands("give " .. amount .. " " .. dm_handle.selectedUnit .. " " .. dm_handle.selectedTeamID)
        return true
    end
end

function widget:Initialize()
    if widget:GetInfo().enabled == false then
        return false
    end

    -- Get the shared RML context
    widget.rmlContext = RmlUi.GetContext("shared")
    if not widget.rmlContext then
        return false
    end

    -- Create and bind the data model
    dm_handle = widget.rmlContext:OpenDataModel(MODEL_NAME, init_model)
    if not dm_handle then
        return false
    end

    -- Load the RML document
    document = widget.rmlContext:LoadDocument(RML_PATH, widget)
    if not document then
        widget:Shutdown()
        return false
    end


	document:AddEventListener("dragend", function() widget:SavePosition() end)

    -- Apply styles and show the document
    document:ReloadStyleSheet()
    document:Show()
	widget:LoadPosition()
    -- Widget initialized successfully

    return true
end

function widget:SavePosition()
    -- Saving widget position
	if not document then return end
	local element = document:GetElementById("gui_ubdev-widget")
	if not element then return end
	local x = element.offset_left
	local y = element.offset_top
	if not x or not y then return end

    local vsx, vsy = spGetViewGeometry()
    if not vsx or not vsy then return end
    local relX = x / vsx
    local relY = y / vsy
    spSetConfigInt("ubdev_RelativeX", math.floor(relX * 1000)) -- store as int to avoid precision issues
    spSetConfigInt("ubdev_RelativeY", math.floor(relY * 1000))
end

function widget:LoadPosition()
	if not document then return end
	local element = document:GetElementById("gui_ubdev-widget")
	if not element then return end
    local relX = spGetConfigInt("ubdev_RelativeX", -1)
    local relY = spGetConfigInt("ubdev_RelativeY", -1)
    if relX == -1 or relY == -1 then return end
    relX = relX / 1000
    relY = relY / 1000
    local vsx, vsy = spGetViewGeometry()
    if not vsx or not vsy then return end
    local x = math.floor(relX * vsx)
    local y = math.floor(relY * vsy)
    element.style.position = "absolute"
    element.style.left = x .. "px"
    element.style.top = y .. "px"
end

function widget:PauseAI()
    local allTeams = spGetTeamList()
    -- Pause or unpause all AI teams
    for _, teamID in ipairs(allTeams) do
        local _, _, _, isAI = spGetTeamInfo(teamID, false)
        if isAI then
            local units = spGetTeamUnits(teamID)
            for _, unitID in pairs(units) do
                local states = spGetUnitStates(unitID)
                if states then
                    if arePausing and states['active'] then
                        -- Pausing: send WAIT to active units
                        spGiveOrderToUnit(unitID, CMD_WAIT, {}, {})
                    elseif not arePausing and not states['active'] then
                        -- Unpausing: send WAIT to units that are waiting
                        spGiveOrderToUnit(unitID, CMD_WAIT, {}, {})
                    end
                end
            end
        end
    end
    -- Paused or unpaused all AI teams
    arePausing = not arePausing
end

function widget:SendCommand(command)
    spSendCommands(command)
end

function widget:Shutdown()
    -- Shutting down widget...

    -- Clean up data model
    if widget.rmlContext and dm_handle then
        widget.rmlContext:RemoveDataModel(MODEL_NAME)
        dm_handle = nil
    end

    -- Close document
    if document then
        document:Close()
        document = nil
    end

    widget.rmlContext = nil

    clearDrawHandles()

    -- Shutdown complete
end

function widget:Update()
    if dm_handle then
        if dm_handle.selectedUnit ~= '' then
            local defID = nameToDefID[dm_handle.selectedUnit]
            -- get the mouse position in world
            local mx, my = spGetMouseState()
            local type, pos = spTraceScreenRay(mx, my, true)

            if type == 'ground' then
                -- Pass prevHandle as updateID and WIDGET_NAME as ownerID
                local handle = WG.DrawUnitShapeGL4(defID, pos[1], pos[2], pos[3], 0, 0.6, dm_handle.selectedTeamID, 0.0, 0.0, drawHandle)
                drawHandle = handle
            else
                clearDrawHandles()
            end
        else
            clearDrawHandles()
        end
    end
end

-- Widget functions callable from RML
function widget:Reload()
    widget:Shutdown()
    widget:Initialize()
end

function widget:ToggleDebugger()
    if dm_handle then
        dm_handle.debugMode = not dm_handle.debugMode

        if dm_handle.debugMode then
            RmlUi.SetDebugContext('shared')
        else
            RmlUi.SetDebugContext(nil)
        end
    end
end
