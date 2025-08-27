---@diagnostic disable: undefined-global, inject-field, undefined-field, need-check-nil, param-type-mismatch
local widget = widget
function widget:GetInfo()
    return {
        name = "Smart Mines",
        desc = "Mines will detonate only when an enemy of appropriate tech level is nearby.",
        author = "uBdead",
        date = "2025-08-11",
        license = "GNU GPL, v2 or later",
        layer = 0,
        enabled = true
    }
end

local PROCESS_MAX_PER_FRAME = 50
local process_index = 1 -- for staggering (1-based for Lua arrays)
local trackedMineList = {} -- array of tracked mine unitIDs for staggered processing

local trackedMines = {} -- trackedMines[unitID] = {x, z, lastState}
local CMD_FIRE_STATE = CMD.FIRE_STATE
local FIRESTATE_HOLD = 0 -- Hold fire
local FIRESTATE_FIRE = 2 -- Fire at will

local spGiveOrderToUnit = Spring.GiveOrderToUnit
local spGetUnitPosition = Spring.GetUnitPosition
local spGetUnitDefID = Spring.GetUnitDefID
local spGetUnitsInCylinder = Spring.GetUnitsInCylinder
local spGetUnitTeam = Spring.GetUnitTeam
local spAreTeamsAllied = Spring.AreTeamsAllied
local spGetMyTeamID = Spring.GetMyTeamID

-- an pair of mine names to tech level to detonate like so name=techLevel
local minesMap = {
    ["cormine2"] = 2,
    ["cormine3"] = 3,
    ["armmine2"] = 2,
    ["armmine3"] = 3,
    ["legmine2"] = 2,
    ["legmine3"] = 3,
}

-- Cache of mine unitDefIDs to mine data (e.g. tech level, radius, etc)
local mineDefinitions = {}

local function cacheMinesUnitDefs()
    for defID, def in pairs(UnitDefs) do
        if def and def.name and minesMap[def.name] then
            -- Add to mineDefinitions (extend as needed)
            mineDefinitions[defID] = {
                techLevel = minesMap[def.name],
                radius = def.customParams and tonumber(def.customParams.detonateradius) or nil,
                name = def.name,
            }
        end
    end
end

local function getTechLevel(defID)
    local def = UnitDefs[defID]
    if not def then return 0 end
    if def.customParams and def.customParams.techlevel then
        return tonumber(def.customParams.techlevel) or 0
    end
    return 0
end

local function updateTrackedMineList()
    trackedMineList = {}
    for unitID in pairs(trackedMines) do
        trackedMineList[#trackedMineList+1] = unitID
    end
end

local function untrackMine(unitID)
    if trackedMines[unitID] then
        trackedMines[unitID] = nil
        updateTrackedMineList()
    end
end

local function maybeTrackMine(unitID, unitDefID)
    if mineDefinitions[unitDefID] then
        -- Only manage mines we can give orders to (own/allied team)
        local myTeamID = spGetMyTeamID()
        if myTeamID and myTeamID >= 0 then
            local unitTeam = spGetUnitTeam(unitID)
            if not spAreTeamsAllied(unitTeam, myTeamID) then
                return
            end
        end
        local x, _, z = spGetUnitPosition(unitID)
        if x and z then
            trackedMines[unitID] = {x = x, z = z, lastState = nil}
            updateTrackedMineList()
            -- Default to hold fire; we'll enable when a valid target is nearby
            spGiveOrderToUnit(unitID, CMD_FIRE_STATE, {FIRESTATE_HOLD}, {})
            trackedMines[unitID].lastState = FIRESTATE_HOLD
        end
    end
end

function widget:Initialize()
    cacheMinesUnitDefs()

    -- update the list for possible existing mines
    -- loop all units (Spring.GetAllUnits returns a list of unitIDs)
    local allUnits = Spring.GetAllUnits()
    for i = 1, #allUnits do
        local unitID = allUnits[i]
        local unitDefID = spGetUnitDefID(unitID)
        if unitDefID then
            maybeTrackMine(unitID, unitDefID)
        end
    end
end

function widget:UnitCreated(unitID, unitDefID)
    maybeTrackMine(unitID, unitDefID)
end

function widget:UnitFinished(unitID, unitDefID)
    -- Ensure we catch mines that only become trackable when finished
    maybeTrackMine(unitID, unitDefID)
end

function widget:UnitDestroyed(unitID)
    untrackMine(unitID)
end

function widget:UnitGiven(unitID, unitDefID, newTeam, oldTeam)
    local myTeamID = spGetMyTeamID()
    if myTeamID and newTeam and spAreTeamsAllied(newTeam, myTeamID) then
        maybeTrackMine(unitID, unitDefID)
    else
        untrackMine(unitID)
    end
end

function widget:UnitTaken(unitID, unitDefID, oldTeam, newTeam)
    local myTeamID = spGetMyTeamID()
    if myTeamID and newTeam and spAreTeamsAllied(newTeam, myTeamID) then
        maybeTrackMine(unitID, unitDefID)
    else
        untrackMine(unitID)
    end
end

function widget:GameFrame(frame)
    local n = #trackedMineList
    if n == 0 then return end
    -- Wrap process_index if list size changed
    if process_index > n then process_index = 1 end
    local startIdx = process_index
    local endIdx = math.min(startIdx + PROCESS_MAX_PER_FRAME - 1, n)
    for i = startIdx, endIdx do
        local unitID = trackedMineList[i]
        -- Find the mine definition for this unit
        local unitDefID = spGetUnitDefID(unitID)
        local mineData = mineDefinitions[unitDefID]
        local pos = trackedMines[unitID]

        -- Spring.Echo("Processing mine", unitID, "at position", pos and pos.x, pos and pos.z)

        if mineData and pos and pos.x and pos.z then
            local radius = mineData.radius or 128 -- fallback radius if not set
            local enemyUnits = spGetUnitsInCylinder(pos.x, pos.z, radius)
            local mineTeam = spGetUnitTeam(unitID)
            local foundValidTarget = false
            for _, enemyID in ipairs(enemyUnits) do
                local enemyTeam = spGetUnitTeam(enemyID)
                if enemyTeam and mineTeam and not spAreTeamsAllied(enemyTeam, mineTeam) then
                    local enemyTechLevel = getTechLevel(spGetUnitDefID(enemyID))
                    if enemyTechLevel >= mineData.techLevel then
                        -- Arm the mine (fire at will) as a valid target is present
                        if not pos.lastState or pos.lastState ~= FIRESTATE_FIRE then
                            spGiveOrderToUnit(unitID, CMD_FIRE_STATE, {FIRESTATE_FIRE}, {})
                            pos.lastState = FIRESTATE_FIRE
                        end
                        foundValidTarget = true
                        break
                    end
                end
            end
            if not foundValidTarget then
                -- Ensure mine won't blow on low-tech units when no valid target is nearby
                if not pos.lastState or pos.lastState ~= FIRESTATE_HOLD then
                    spGiveOrderToUnit(unitID, CMD_FIRE_STATE, {FIRESTATE_HOLD}, {})
                    pos.lastState = FIRESTATE_HOLD
                end
            end
        end
    end
    process_index = endIdx + 1
    if process_index > n then
        process_index = 1
    end
end

function widget:Shutdown()
    -- Restore mines to Fire At Will in case the widget is disabled/unloaded
    for unitID in pairs(trackedMines) do
        spGiveOrderToUnit(unitID, CMD_FIRE_STATE, {FIRESTATE_FIRE}, {})
    end
end
