---@diagnostic disable: undefined-global, inject-field, undefined-field, need-check-nil, param-type-mismatch
local widget = widget
function widget:GetInfo()
    return {
        name = "Lazy Reclaimers",
        desc = "Reclaimers will stop reclaiming when the metal/energy storage is full.",
        author = "uBdead",
        date = "2025-09-16",
        license = "GNU GPL, v2 or later",
        layer = 0,
        enabled = true,
		handler = true,
    }
end

local RESOURCE_TOLERANCE              = 0.95
local RECLAIMERS_ORDER_CHECK_INTERVAL = 15 -- check every 15 frames (0.5 seconds at 30 FPS)
local FULL_CHECK_INTERVAL             = 5  -- check every 5 frames (0.166 seconds at 30 FPS)
local FULL_RECLAIMERS_REBUILD         = 300 -- rebuild the reclaimer list every 300 frames (10 seconds at 30 FPS)

-- Cache Spring API functions locally for faster access (Lua global/table lookups are slower)
local spGetTeamList                   = Spring.GetTeamList
local spGetTeamResources              = Spring.GetTeamResources
local spGetTeamUnits                  = Spring.GetTeamUnits
local spGetUnitDefID                  = Spring.GetUnitDefID
-- local spEcho                          = Spring.Echo
local spGetMyAllyTeamID               = Spring.GetMyAllyTeamID
local spGetMyTeamID                   = Spring.GetMyTeamID
local spGetTeamInfo                   = Spring.GetTeamInfo
local spGetUnitPosition               = Spring.GetUnitPosition
local spGetUnitRadius                 = Spring.GetUnitRadius
local spGetFeaturePosition            = Spring.GetFeaturePosition
local spGetFeatureRadius              = Spring.GetFeatureRadius
local spGetFeatureResources           = Spring.GetFeatureResources
local spGetUnitCommands               = Spring.GetUnitCommands
local spIsUnitSelected                = Spring.IsUnitSelected
local spGiveOrderToUnit               = Spring.GiveOrderToUnit
-- local spGetGameFrame                  = Spring.GetGameFrame

local reclaimerDefIDs                 = {} -- [unitDefID] = buildDistance
local unitDefIDToResources            = {} -- [unitDefID] = {metal = x}
local myAllyTeamID
local myTeamID
local reclaimers                      = {} -- [unitID] = {paused = bool, reclaiming = bool, type = "feature"/"unit"}
local reclaimersOrderCheckLastFrame   = 0
local fullCheckLastFrame              = 0
local fullReclaimersRebuildLastFrame  = 0

local function updateReclaimers()
    local units = spGetTeamUnits(myTeamID)
    for _, unitID in ipairs(units) do
        local unitDefID = spGetUnitDefID(unitID)
        if unitDefID then
            if reclaimerDefIDs[unitDefID] and not reclaimers[unitID] then
                reclaimers[unitID] = {
                    paused = false,
                    reclaiming = false,
                    metal = 0,
                    energy = 0,
                    type = nil,
                }
                -- Spring.Echo("Lazy Reclaimers: Found reclaimer unit", unitID)
            end
        else
            reclaimers[unitID] = nil
        end
    end
end

function widget:UnitCreated(unitID, unitDefID, unitTeam)
    if unitTeam == myTeamID and reclaimerDefIDs[unitDefID] then
        reclaimers[unitID] = {
            paused = false,
            reclaiming = false,
            metal = 0,
            energy = 0,
            type = nil,
        }
    end
end

function widget:UnitDestroyed(unitID)
    reclaimers[unitID] = nil
end

local function maybeRemoveSelf()
    if Spring.GetSpectatingState() and (Spring.GetGameFrame() > 0 or gameStarted) then
        widgetHandler:RemoveWidget()
    end
end

function widget:Initialize()
    if Spring.IsReplay() then
        maybeRemoveSelf()
    end

    myAllyTeamID = spGetMyAllyTeamID()
    myTeamID = spGetMyTeamID()

    for unitDefID, unitDef in pairs(UnitDefs) do
        if unitDef.canReclaim and not unitDef.isBuilding and unitDef.speed > 0 then
            reclaimerDefIDs[unitDefID] = unitDef.buildDistance
        end

        unitDefIDToResources[unitDefID] = {
            metal = unitDef.metalCost or 0,
        }
    end

    updateReclaimers()
end

local function isTeamFullResource(teamID, resourceType)
    local current, storage = spGetTeamResources(teamID, resourceType)
    if current and storage then
        return (current >= (storage * RESOURCE_TOLERANCE))
    end
    return false
end

local function isAllyTeamFullResource(allyTeamID, resourceType)
    local teamList = spGetTeamList()
    local allFull = true
    for _, teamID in ipairs(teamList) do
        local teamAllyTeamID = select(6, spGetTeamInfo(teamID))
        if teamAllyTeamID == allyTeamID then
            if not isTeamFullResource(teamID, resourceType) then
                allFull = false
                break
            end
        end
    end
    return allFull
end

local function isAllyTeamFullEnergy(allyTeamID)
    return isAllyTeamFullResource(allyTeamID, "energy")
end

local function isAllyTeamFullMetal(allyTeamID)
    return isAllyTeamFullResource(allyTeamID, "metal")
end

local function isTeamFullEnergy(teamID)
    return isTeamFullResource(teamID, "energy")
end

local function isTeamFullMetal(teamID)
    return isTeamFullResource(teamID, "metal")
end

local function processReclaimOrder(unitID, cmd)
    local unitDefID = spGetUnitDefID(unitID)
    local buildDistance = reclaimerDefIDs[unitDefID] or 0
    local ux, uy, uz = spGetUnitPosition(unitID)
    local tx, ty, tz, objectRadius
    local id = cmd.params[1]
    objectRadius = 0

    local metal = 0
    local energy = 0
    local type = "feature"

    if id < Game.maxUnits then
        type = "unit"
        tx, _, tz = spGetUnitPosition(id)
        if tx then
            if spGetUnitRadius then
                objectRadius = spGetUnitRadius(id) or 0
            end
        end

        local unitDefId = spGetUnitDefID(id)
        metal = unitDefIDToResources[unitDefId].metal or 0
        energy = 0
    elseif id >= Game.maxUnits then
        local fid = id - Game.maxUnits
        tx, ty, tz = spGetFeaturePosition(fid)
        if tx then
            if spGetFeatureRadius then
                objectRadius = spGetFeatureRadius(fid) or 0
            end
        end

        local fMetal, _, fEnergy = spGetFeatureResources(fid)
        metal = fMetal or 0
        energy = fEnergy or 0
    end

    if tx then
        local dx = ux - tx
        local dz = uz - tz
        local distance = math.sqrt(dx * dx + dz * dz) - objectRadius
        if distance <= buildDistance then
            -- Spring.Echo(Spring.GetGameFrame(), "Lazy Reclaimers: Reclaimer", unitID, "reclaiming a", type, "worth", metal,"metal and", energy, "energy")
            reclaimers[unitID].paused = false
            reclaimers[unitID].reclaiming = true
            reclaimers[unitID].metal = metal
            reclaimers[unitID].energy = energy
            reclaimers[unitID].type = type
        else
            reclaimers[unitID].paused = false
            reclaimers[unitID].reclaiming = false
            reclaimers[unitID].metal = 0
            reclaimers[unitID].energy = 0
            reclaimers[unitID].type = nil
        end
    end
end

local function checkIsReclaiming()
    for unitID, state in pairs(reclaimers) do
        local orders = spGetUnitCommands(unitID, 2)
        -- check if the second order is negative, meaning we want to build something
        if orders and #orders >= 2 then
            if orders[2].id < 0 then
                reclaimers[unitID].paused = false
                reclaimers[unitID].reclaiming = false
                reclaimers[unitID].metal = 0
                reclaimers[unitID].energy = 0
                reclaimers[unitID].type = nil
                -- Spring.Echo("Lazy Reclaimers: Reclaimer", unitID, "is building something, resetting reclaim state")
                return
            end
        end

        if orders and #orders >= 1 then
            local cmd = orders[1]
            if cmd.id == CMD.RECLAIM and cmd.params and (cmd.params[1] > Game.maxUnits or #cmd.params == 1) then
                processReclaimOrder(unitID, cmd)
            elseif cmd.id == CMD.WAIT then
                reclaimers[unitID].paused = true
            else
                reclaimers[unitID].paused = false
                reclaimers[unitID].reclaiming = false
            end
        else
            -- Spring.Echo("Lazy Reclaimers: Reclaimer", unitID, "is idle, resetting reclaim state")
            reclaimers[unitID].paused = false
            reclaimers[unitID].reclaiming = false
        end
    end
end

local function checkFull()
    local metalFull = isAllyTeamFullMetal(myAllyTeamID)
    local energyFull = isAllyTeamFullEnergy(myAllyTeamID)

    for unitID, state in pairs(reclaimers) do
        if not spIsUnitSelected(unitID) and state.reclaiming then
            local shouldPause = (metalFull and state.metal > 0) or (energyFull and state.energy > 0)

            if shouldPause and not state.paused then
                -- Pause the reclaimer
                spGiveOrderToUnit(unitID, CMD.WAIT, {}, { "right" })
                reclaimers[unitID].paused = true
            elseif not shouldPause and state.paused then
                -- Resume the reclaimer
                spGiveOrderToUnit(unitID, CMD.WAIT, {}, {})
                reclaimers[unitID].paused = false
            end
        end
    end
end

-- local function DrawReclaimerDebug()
--     for unitID, state in pairs(reclaimers) do
--         local x, y, z = Spring.GetUnitPosition(unitID)
--         if x and y and z then
--             local color
--             if state.paused then
--                 color = {1, 1, 0, 0.7} -- yellow
--             elseif state.reclaiming then
--                 color = {0, 1, 0, 0.7} -- green
--             else
--                 color = {0.5, 0.5, 0.5, 0.7} -- gray
--             end
--             local label = string.format(
--                 "Paused: %s\nReclaiming: %s\nMetal: %s\nEnergy: %s\nType: %s",
--                 tostring(state.paused),
--                 tostring(state.reclaiming),
--                 tostring(state.metal),
--                 tostring(state.energy),
--                 tostring(state.type)
--             )
--             gl.PushMatrix()
--             gl.Translate(x, y + 30, z)
--             gl.Color(color)
--             gl.Billboard()
--             gl.DrawGroundCircle(0, 0, 0, 10, 20)
--             gl.Text(label, 0, 12, 10, "oc")
--             gl.PopMatrix()
--         end
--     end
-- end

-- function widget:DrawWorld()
--     DrawReclaimerDebug()
-- end

function widget:GameFrame(frame)
    if (frame - fullReclaimersRebuildLastFrame) >= FULL_RECLAIMERS_REBUILD then
        updateReclaimers()
        fullReclaimersRebuildLastFrame = frame
    end

    if (frame - reclaimersOrderCheckLastFrame) >= RECLAIMERS_ORDER_CHECK_INTERVAL then
        checkIsReclaiming()
        reclaimersOrderCheckLastFrame = frame
    end

    if (frame - fullCheckLastFrame) >= FULL_CHECK_INTERVAL then
        checkFull()
    end
end

