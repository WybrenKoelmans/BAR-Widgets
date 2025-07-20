local widget = widget ---@type Widget

-- Performance optimizations
local spGetCommandCount = Spring.GetUnitCommandCount
local spGetMyTeamID = Spring.GetMyTeamID
local spGetUnitsInCylinder = Spring.GetUnitsInCylinder
local spGetUnitPosition = Spring.GetUnitPosition
local spGetUnitHealth = Spring.GetUnitHealth
local spGetUnitTeam = Spring.GetUnitTeam
local spGetUnitDefID = Spring.GetUnitDefID
local spGiveOrderToUnit = Spring.GiveOrderToUnit
local spAreTeamsAllied = Spring.AreTeamsAllied

-- Commands
local CMD_REPAIR = CMD.REPAIR

local repairUnitDefs = {}
local repairUnits = {} -- [unitID] = {defID = unitDefID, range = range}
local myTeamID
local checkIndex = 0 -- For staggered processing

function widget:GetInfo()
    return {
        name = "Idle Auto Repair",
        desc = "Idle repair units automatically repair nearby damaged allied units in range",
        author = "uBdead",
        date = "2025-07-20",
        license = "GNU GPL, v2 or later",
        layer = 0,
        enabled = true
    }
end

function PrecacheRepairUnitDefs()
    for defID, def in pairs(UnitDefs) do
        if def.canRepair and def.buildDistance and def.buildDistance > 0 then
            repairUnitDefs[defID] = def.buildDistance
        end
    end
end

-- Convert repairUnits table to array for more efficient iteration
local repairUnitsArray = {}
local repairUnitsCount = 0

local function updateRepairUnitsArray()
    repairUnitsCount = 0
    for unitID, unitData in pairs(repairUnits) do
        repairUnitsCount = repairUnitsCount + 1
        repairUnitsArray[repairUnitsCount] = {unitID = unitID, data = unitData}
    end
end

function widget:Initialize()
    myTeamID = spGetMyTeamID()
    PrecacheRepairUnitDefs()
    
    -- Process existing units
    local allUnits = Spring.GetAllUnits()
    for i = 1, #allUnits do
        local unitID = allUnits[i]
        local unitDefID = spGetUnitDefID(unitID)
        local unitTeam = spGetUnitTeam(unitID)
        if repairUnitDefs[unitDefID] and unitTeam == myTeamID then
            repairUnits[unitID] = {
                defID = unitDefID,
                range = repairUnitDefs[unitDefID]
            }
        end
    end
    
    updateRepairUnitsArray()
end

-- Handle player changes (spectator mode, team changes)
function widget:PlayerChanged(playerID)
    local newTeamID = spGetMyTeamID()
    if newTeamID ~= myTeamID then
        myTeamID = newTeamID
        -- Clear and rebuild repair units list
        repairUnits = {}
        repairUnitsCount = 0
        widget:Initialize()
    end
end

function widget:UnitCreated(unitID, unitDefID, unitTeam, builderID)
    if repairUnitDefs[unitDefID] and unitTeam == myTeamID then
        repairUnits[unitID] = {
            defID = unitDefID,
            range = repairUnitDefs[unitDefID]
        }
        -- Mark array as needing update
        repairUnitsCount = 0
    end
end

function widget:UnitDestroyed(unitID, unitDefID, unitTeam, attackerID, attackerDefID, attackerTeam, weaponDefID)
    if repairUnits[unitID] then
        repairUnits[unitID] = nil
        -- Mark array as needing update
        repairUnitsCount = 0
    end
end

function widget:UnitGiven(unitID, unitDefID, unitTeam, oldTeam)
    if repairUnitDefs[unitDefID] then
        if unitTeam == myTeamID then
            repairUnits[unitID] = {
                defID = unitDefID,
                range = repairUnitDefs[unitDefID]
            }
        else
            repairUnits[unitID] = nil
        end
        -- Mark array as needing update
        repairUnitsCount = 0
    end
end

function widget:UnitTaken(unitID, unitDefID, unitTeam, newTeam)
    if repairUnitDefs[unitDefID] then
        if newTeam == myTeamID then
            repairUnits[unitID] = {
                defID = unitDefID,
                range = repairUnitDefs[unitDefID]
            }
        else
            repairUnits[unitID] = nil
        end
        -- Mark array as needing update
        repairUnitsCount = 0
    end
end

function widget:GameFrame(n)
    -- Only check every 30 frames, stagger units to spread load
    if n % 30 ~= 0 then
        return
    end
    
    -- Update array if needed (when units are added/removed)
    if repairUnitsCount == 0 or repairUnitsCount ~= 0 and not repairUnitsArray[1] then
        updateRepairUnitsArray()
        if repairUnitsCount == 0 then
            return
        end
    end
    
    checkIndex = checkIndex + 1
    if checkIndex > repairUnitsCount then
        checkIndex = 1
    end
    
    -- Process a subset of units each frame
    local unitsToCheck = math.min(5, repairUnitsCount) -- Check at most 5 units per frame
    for i = 1, unitsToCheck do
        local arrayIndex = ((checkIndex - 1 + i - 1) % repairUnitsCount) + 1
        local unitInfo = repairUnitsArray[arrayIndex]
        if unitInfo and repairUnits[unitInfo.unitID] then -- Verify unit still exists
            CheckAndRepairUnit(unitInfo.unitID, unitInfo.data)
        end
    end
end

function CheckAndRepairUnit(unitID, unitData)
    -- Check if the unit is idle first (cheapest check)
    local isIdle = spGetCommandCount(unitID) == 0
    if not isIdle then
        return
    end
    
    local posX, posY, posZ = spGetUnitPosition(unitID)
    if not posX then
        -- Unit doesn't exist anymore, remove from tracking
        repairUnits[unitID] = nil
        return
    end

    local unitRange = unitData and unitData.range or repairUnitDefs[spGetUnitDefID(unitID)]
    if not unitRange then
        return
    end

    local nearbyUnits = spGetUnitsInCylinder(posX, posZ, unitRange)
    local targetUnit = nil
    local targetHealth = 1.0 -- Start with full health, find most damaged
    
    for _, targetUnitID in ipairs(nearbyUnits) do
        if targetUnitID ~= unitID then
            local targetTeam = spGetUnitTeam(targetUnitID)
            -- Check if target is allied (same team or allied team)
            if targetTeam and (targetTeam == myTeamID or spAreTeamsAllied(myTeamID, targetTeam)) then
                local health, maxHealth = spGetUnitHealth(targetUnitID)
                if health and maxHealth and health < maxHealth then
                    local healthRatio = health / maxHealth
                    -- Prioritize units with lower health percentage
                    if healthRatio < targetHealth then
                        targetUnit = targetUnitID
                        targetHealth = healthRatio
                    end
                end
            end
        end
    end
    
    if targetUnit then
        spGiveOrderToUnit(unitID, CMD_REPAIR, { targetUnit }, 0)
    end
end
