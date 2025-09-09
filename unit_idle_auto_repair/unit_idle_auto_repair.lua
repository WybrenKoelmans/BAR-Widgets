local widget = widget ---@type Widget

-- Cache Spring.* functions
local spIsUnitSelected = Spring.IsUnitSelected
local spGetUnitStates = Spring.GetUnitStates
local spGetUnitDefID = Spring.GetUnitDefID
local spGetUnitTeam = Spring.GetUnitTeam
local spGetUnitHealth = Spring.GetUnitHealth
local spGetUnitVelocity = Spring.GetUnitVelocity
local spGetUnitPosition = Spring.GetUnitPosition
local spGetUnitsInSphere = Spring.GetUnitsInSphere
local spGiveOrderToUnit = Spring.GiveOrderToUnit
local spGetMyTeamID = Spring.GetMyTeamID
local spGetTeamUnits = Spring.GetTeamUnits
local spGetUnitCommands = Spring.GetUnitCommands
local spAreTeamsAllied = Spring.AreTeamsAllied

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

------ TODO: ------
--- unreachable targets? (water? timeout+blacklist?)

local ignoreUnitDefIds = {}
local ignoreUnitDefNames = {
    cordrag = true, -- ignore walls
    armdrag = true, -- ignore walls
    legdrag = true, -- ignore walls
}

-- Commands
local CMD_REPAIR = CMD.REPAIR
local CMD_STOP = CMD.STOP
local CMD_MOVE = CMD.MOVE

local repairersUnitDefIDs = {}   -- unitDefID -> build distance
local repairOrders = {}          -- unitID -> {startPosX, startPosY, startPosZ, targetUnitID, buildDistance}
local lastFrameExecuted = 0
local REPAIR_CHECK_INTERVAL = 30 -- frames

function widget:Initialize()
    local allUnitDefs = UnitDefs
    for unitDefID, unitDef in pairs(allUnitDefs) do
        if unitDef.canRepair and unitDef.buildDistance > 0 and not unitDef.isBuilding then
            repairersUnitDefIDs[unitDefID] = unitDef.buildDistance
        end

        if ignoreUnitDefNames[unitDef.name] then
            ignoreUnitDefIds[unitDefID] = true
        end
    end
end

local function unitChecksForRepairTarget(x, y, z, unitID, unitDefID, myTeamID)
    if spIsUnitSelected(unitID) then
        return false
    end

    local states = spGetUnitStates(unitID)
    local moveState = states and states["movestate"]

    local buildDistance = repairersUnitDefIDs[unitDefID]
    local mobileBuildDistance = buildDistance
    local staticBuildDistance = buildDistance
    -- multiply the distance based on the movestate
    if moveState == 1 then     -- Maneuver
        staticBuildDistance = buildDistance * 2
    elseif moveState == 2 then -- Roam
        staticBuildDistance = buildDistance * 4
    end

    local nearbyUnits = spGetUnitsInSphere(x, y, z, staticBuildDistance)
    for _, targetUnitID in ipairs(nearbyUnits) do
        if targetUnitID ~= unitID and not ignoreUnitDefIds[spGetUnitDefID(targetUnitID)] then
            -- TODO: ideally we filter out out of range units that are going to be cancelled when they move
            local targetTeamID = spGetUnitTeam(targetUnitID)
            if targetTeamID == myTeamID or spAreTeamsAllied(myTeamID, targetTeamID) then
                local targetHealth, targetMaxHealth = spGetUnitHealth(targetUnitID)
                if targetHealth and targetMaxHealth and targetHealth < targetMaxHealth then
                    -- Spring.Echo("Auto repairing unitID:", targetUnitID, "by repairer unitID:", unitID)

                    -- check if the target is moving, because the range should be in buildDistance in that case
                    local _, _, _, v = spGetUnitVelocity(targetUnitID)
                    local giveOrder = false
                    if v and (v > 0.1) then
                        local x1, _, z1 = spGetUnitPosition(unitID)
                        local x2, _, z2 = spGetUnitPosition(targetUnitID)
                        local dx = x1 - x2
                        local dz = z1 - z2
                        local dist2D = math.sqrt(dx * dx + dz * dz) -- TODO: square the mobileBuildDistance instead so we dont do it for every loop
                        if dist2D <= mobileBuildDistance then
                            giveOrder = true
                        end
                    else
                        giveOrder = true
                    end

                    if giveOrder then
                        spGiveOrderToUnit(unitID, CMD_REPAIR, { targetUnitID })
                        repairOrders[unitID] = { x, y, z, targetUnitID, repairersUnitDefIDs[unitDefID] }
                        return true
                    end
                end
            end
        end
    end

    return false
end

local function validateRepairOrders()
    for unitID, order in pairs(repairOrders) do
        if not spIsUnitSelected(unitID) then
            -- get the target unit velocity
            local targetUnitID = order[4]
            local _, _, _, v = spGetUnitVelocity(targetUnitID)
            if v and (v > 0.1) then
                -- Check the distance to the target unit, if its outside the build range of the repairer, cancel the order
                local _, _, _, _, buildDistance = unpack(order)
                local unitX, unitY, unitZ = spGetUnitPosition(unitID)
                local targetX, targetY, targetZ = spGetUnitPosition(targetUnitID)
                if unitX and targetX then
                    local dx = unitX - targetX
                    local dy = unitY - targetY
                    local dz = unitZ - targetZ
                    local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
                    if dist > buildDistance then
                        -- Spring.Echo("Auto repair cancelled for unitID:", unitID, "targetUnitID:", targetUnitID, "out of range")
                        spGiveOrderToUnit(unitID, CMD_STOP, {}, 0)
                        repairOrders[unitID] = nil
                    end
                end
            end
        end
    end
end

function widget:GameFrame(frame)
    if frame < lastFrameExecuted + REPAIR_CHECK_INTERVAL then
        return
    end
    lastFrameExecuted = frame

    local myTeamID = spGetMyTeamID()
    local myUnits = spGetTeamUnits(myTeamID)

    validateRepairOrders()

    for _, unitID in ipairs(myUnits) do
        local unitDefID = spGetUnitDefID(unitID)
        if repairersUnitDefIDs[unitDefID] and not repairOrders[unitID] then
            local commands = spGetUnitCommands(unitID, 1)
            if commands and #commands < 1 then
                local x, y, z = spGetUnitPosition(unitID)
                unitChecksForRepairTarget(x, y, z, unitID, unitDefID, myTeamID)
            end
        end
    end
end

function widget:UnitIdle(unitID, unitDefID, unitTeam)
    if spIsUnitSelected(unitID) then
        return
    end

    if repairOrders[unitID] then
        local startPosX, startPosY, startPosZ, targetUnitID = unpack(repairOrders[unitID])
        local states = spGetUnitStates(unitID)
        local moveState = states and states["movestate"]

        if moveState == 1 then -- Maneuver
            -- immediately check if compared to our old position, we should do another order
            local gaveOrder = unitChecksForRepairTarget(startPosX, startPosY, startPosZ, unitID, unitDefID, unitTeam)
            if not gaveOrder then
                spGiveOrderToUnit(unitID, CMD_MOVE, { startPosX, startPosY, startPosZ }, {})
                repairOrders[unitID] = nil
            end
        else
            repairOrders[unitID] = nil
        end
    end
end

function widget:UnitCommand(unitID, unitDefID, unitTeam, cmdID, cmdParams, cmdOpts, cmdTag)
    -- Unless this is the exact repair command we issued, cancel the auto-repair order
    if repairOrders[unitID] then
        if cmdID ~= CMD_REPAIR or (cmdParams[1] ~= repairOrders[unitID][4]) then
            repairOrders[unitID] = nil
            -- Spring.Echo("Auto repair cancelled for unitID:", unitID)
        end
    end
end
