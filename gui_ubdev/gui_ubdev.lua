-- luacheck: globals widget RmlUi CMD ---@type Widget
if not RmlUi then
    return
end

-- Cache Spring.* and CMD.* as local variables for optimization
local spGetAIInfo = Spring.GetAIInfo
local spGetGameRulesParam = Spring.GetGameRulesParam
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
        author = "uBdead, Steel",
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

--------------------------------------------------------------------------------

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
    local aHasUnitPic = string.find(a.imgPath, "unitpics", 1, true) ~= nil
    local bHasUnitPic = string.find(b.imgPath, "unitpics", 1, true) ~= nil
    if aHasUnitPic ~= bHasUnitPic then
        return aHasUnitPic
    end
    return a.humanName < b.humanName
end)

function GetAIName(teamID)
    local _, _, _, name, _, options = spGetAIInfo(teamID)
    local niceName = spGetGameRulesParam('ainame_' .. teamID)
    if niceName then
        name = niceName
    end
    return name or ("AI [" .. teamID .. "]")
end

local teamList = spGetTeamList()
local teamsNeedRebuild = true  -- flag to rebuild AI names after game fully loads

local function buildTeams()
    local teams = {}
    for i = 1, #teamList do
        local id, leader, isDead, hasAI = spGetTeamInfo(teamList[i], false)
        local teamName = spGetPlayerInfo(leader, false) or "gaia"
        if teamName then
            local r,g,b,a = Spring.GetTeamColor(teamList[i])
            teams[i] = {
                id = id,
                name = hasAI and GetAIName(teamList[i]) or teamName,
                color = (string.format("rgba(%d, %d, %d, %0.2f)", r*255, g*255, b*255, a*255)),
            }
        end
    end
    return teams
end


-- Initial data model
local init_model = {
    debugMode = false,
    globallosEnabled = false,
    cheatEnabled = false,
    godmodeEnabled = false,
    nocostEnabled = false,
    units = allUnits,
    selectedUnit = '',
    unitsFilterText = '',
    unitsFilterTechLevel = 0,
    unitsFilterFaction = '',
    unitsFilterIsMobile = -1,
    selectedTeamID = spGetMyTeamID(),
    teams = buildTeams(),
    favorites = favorites,
    -- Window controls
    isCollapsed = false,
    toggleCollapse = function(ev)
        dm_handle.isCollapsed = not dm_handle.isCollapsed
    end,
    closeWidget = function(ev)
        if document then document:Close() end
        local ctx = RmlUi.GetContext("shared")
        if ctx and dm_handle then
            ctx:RemoveDataModel(MODEL_NAME)
        end
        widgetHandler:RemoveWidget(widget)
    end,
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
            local aHasUnitPic = string.find(a.imgPath, "unitpics", 1, true) ~= nil
            local bHasUnitPic = string.find(b.imgPath, "unitpics", 1, true) ~= nil
            if aHasUnitPic ~= bHasUnitPic then
                return aHasUnitPic
            end
            return a.humanName < b.humanName
        end)
        dm_handle.units = filtered
    end,
    sendCommand = function(ev, command)
        widget:SendCommand(command)
    end,
    updateTeam = function(ev)
        dm_handle.selectedTeamID = ev.parameters.value
        -- Don't send "team X" here — that moves you onto the team.
        -- selectedTeamID is used as the target for give commands only.
    end,
    onInputFocus = function()
        Spring.SDLStartTextInput()
    end,
    onInputBlur = function()
        Spring.SDLStopTextInput()
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

    widget.rmlContext = RmlUi.GetContext("shared")
    if not widget.rmlContext then
        return false
    end

    dm_handle = widget.rmlContext:OpenDataModel(MODEL_NAME, init_model)
    if not dm_handle then
        return false
    end

    document = widget.rmlContext:LoadDocument(RML_PATH, widget)
    if not document then
        widget:Shutdown()
        return false
    end

    document:AddEventListener("dragend", function() widget:SavePosition() end)

    document:ReloadStyleSheet()
    document:Show()
    widget:LoadPosition()

    return true
end

function widget:SavePosition()
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
    spSetConfigInt("ubdev_RelativeX", math.floor(relX * 1000))
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
    for _, teamID in ipairs(allTeams) do
        local _, _, _, isAI = spGetTeamInfo(teamID, false)
        if isAI then
            local units = spGetTeamUnits(teamID)
            for _, unitID in pairs(units) do
                local states = spGetUnitStates(unitID)
                if states then
                    if arePausing and states['active'] then
                        spGiveOrderToUnit(unitID, CMD_WAIT, {}, {})
                    elseif not arePausing and not states['active'] then
                        spGiveOrderToUnit(unitID, CMD_WAIT, {}, {})
                    end
                end
            end
        end
    end
    arePausing = not arePausing
end

function widget:KeyPress(key, mods, isRepeat, label, unicode)
    if key == 27 then -- ESC key
        dm_handle.selectedUnit = ''
        clearDrawHandles()
        return true
    end
    return false
end

function widget:SendCommand(command)
    spSendCommands(command)
end

function widget:Shutdown()
    Spring.SDLStopTextInput()
    if widget.rmlContext and dm_handle then
        widget.rmlContext:RemoveDataModel(MODEL_NAME)
        dm_handle = nil
    end

    if document then
        document:Close()
        document = nil
    end

    widget.rmlContext = nil
    clearDrawHandles()
end

local teamsRebuildTick = 0

function widget:Update()
    -- Rebuild AI team names once after ~3 seconds — spGetGameRulesParam
    -- 'ainame_X' is not populated at module load time, only after game starts.
    if teamsNeedRebuild and dm_handle then
        teamsRebuildTick = teamsRebuildTick + 1
        if teamsRebuildTick >= 90 then
            dm_handle.teams = buildTeams()
            teamsNeedRebuild = false
        end
    end

    if dm_handle then
        if dm_handle.selectedUnit ~= '' then
            local defID = nameToDefID[dm_handle.selectedUnit]
            local mx, my = spGetMouseState()
            local type, pos = spTraceScreenRay(mx, my, true)

            if type == 'ground' then
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

function widget:SelectionChanged(selectedUnits)
    if not dm_handle then return end
    if selectedUnits and #selectedUnits > 0 then
        local teamID = Spring.GetUnitTeam(selectedUnits[1])
        if teamID then
            dm_handle.selectedTeamID = teamID
        end
    end
end

function widget:GameStart()
    teamsNeedRebuild = true
    teamsRebuildTick = 0
end

function widget:RecvLuaMsg(message, playerID)
    if not document then return end
    if message:sub(1, 19) == 'LobbyOverlayActive1' then
        document:Hide()
    elseif message:sub(1, 19) == 'LobbyOverlayActive0' then
        document:Show()
    end
end

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
