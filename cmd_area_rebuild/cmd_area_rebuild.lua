local widget = widget ---@type Widget

function widget:GetInfo()
    return {
        name = "Area Rebuild",
        desc = "Rebuilds the selected area.",
        author = "uBdead",
        date = "2025-10-08",
        license = "GNU GPL, v2 or later",
        layer = 0,
        enabled = true
    }
end

--[[ TODO: 
    - only give order for correct tier unit (otherwise we can remove ghosts that are not buildable)
--]]

local spGetMyTeamID = Spring.GetMyTeamID
local spGetUnitIsBeingBuilt = Spring.GetUnitIsBeingBuilt
local spGetUnitPosition = Spring.GetUnitPosition
local spGetUnitHeading = Spring.GetUnitHeading
local spGetGameFrame = Spring.GetGameFrame
local spGetSelectedUnits = Spring.GetSelectedUnits
local spGiveOrderToUnitArray = Spring.GiveOrderToUnitArray
local spGetModKeyState = Spring.GetModKeyState
local spGetActiveCommand = Spring.GetActiveCommand

local drawUnitShapeGL4OwnerId = 1337
local CMD_REPAIR = CMD.REPAIR
local rebuildableUnitDefIDs = {}
local destroyedBuildings = {}
local myTeamID = spGetMyTeamID()
local ghosts = {}
local framesRepairKeyHeld = 0

local function tableCount(t)
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    return count
end

function widget:Initialize()
    for unitDefID, unitDef in pairs(UnitDefs) do
        if unitDef.isBuilding and not unitDef.canMove then
            table.insert(rebuildableUnitDefIDs, unitDefID)
        end
    end
end

function widget:UnitDestroyed(unitID, unitDefID, unitTeam, attackerID, attackerDefID, attackerTeam, weaponDefID)
    if unitTeam ~= myTeamID then
        return
    end
    if weaponDefID == -10 then return end -- ignore self-destructions
    if weaponDefID == -12 then return end -- ignore reclaimed
    if weaponDefID == -15 then return end -- ignore still under factory construction
    if weaponDefID == -16 then return end -- ignore factory cancellation
    if weaponDefID == -19 then return end -- ignore decayed

    if rebuildableUnitDefIDs[unitDefID] then
        -- check if this is still under construction
        local beingBuilt = spGetUnitIsBeingBuilt(unitID)
        if beingBuilt then return end

        local x, y, z = spGetUnitPosition(unitID)
        destroyedBuildings[unitID] = {
            unitDefID = unitDefID,
            position = { x = x, y = y, z = z },
            facing = spGetUnitHeading(unitID),
            frame = spGetGameFrame()
        }
    end
end

function widget:UnitFinished(unitID, unitDefID, unitTeam)
    if unitTeam ~= myTeamID then
        return
    end

    -- get the position, if the position is the same, remove from destroyedBuildings
    local x, y, z = spGetUnitPosition(unitID)
    -- account for some floating point inaccuracies by rounding
    x = math.floor(x + 0.5)
    y = math.floor(y + 0.5)
    z = math.floor(z + 0.5)

    for destroyedUnitID, data in pairs(destroyedBuildings) do
        local x2, y2, z2 = data.position.x, data.position.y, data.position.z
        x2 = math.floor(x2 + 0.5)
        y2 = math.floor(y2 + 0.5)
        z2 = math.floor(z2 + 0.5)
        if x2 == x and y2 == y and z2 == z then
            destroyedBuildings[destroyedUnitID] = nil
            if ghosts[destroyedUnitID] then
                WG.StopDrawUnitShapeGL4(ghosts[destroyedUnitID])
                ghosts[destroyedUnitID] = nil
            end
            break
        end
    end
end

function widget:CommandNotify(cmdID, cmdParams, cmdOptions)
    if cmdID == CMD_REPAIR and #cmdParams == 4 then
        local x, y, z = cmdParams[1], cmdParams[2], cmdParams[3]
        local radius = cmdParams[4]

        local orders = {}
        for unitID, data in pairs(destroyedBuildings) do
            local dx = data.position.x - x
            local dy = data.position.y - y
            local dz = data.position.z - z
            local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
            if distance <= radius then
                -- Correct conversion from heading (0-65535) to cardinal direction (0-3)
                local cardinal = math.floor((data.facing / 16384) + 0.5) % 4
                table.insert(orders, {
                    -data.unitDefID,
                    { data.position.x, data.position.y, data.position.z, cardinal }
                })
            end
        end

        if #orders == 0 then
            return false
        end

        -- Rebuild the buildings
        local selectedUnits = spGetSelectedUnits()
        if selectedUnits and #selectedUnits > 0 then
            if not cmdOptions.shift then
                spGiveOrderToUnitArray(selectedUnits, CMD.STOP)
            end

            for _, order in ipairs(orders) do
                spGiveOrderToUnitArray(selectedUnits, order[1], order[2], { "shift" })
            end

            -- remove the destroyedBuildings and ghosts for the rebuilt buildings
            for _, order in ipairs(orders) do
                for destroyedUnitID, data in pairs(destroyedBuildings) do
                    if data.unitDefID == -order[1] and data.position.x == order[2][1] and data.position.y == order[2][2] and data.position.z == order[2][3] then
                        destroyedBuildings[destroyedUnitID] = nil
                        if ghosts[destroyedUnitID] then
                            WG.StopDrawUnitShapeGL4(ghosts[destroyedUnitID])
                            ghosts[destroyedUnitID] = nil
                        end
                        break
                    end
                end
            end

            return true
        else
            return false
        end
    end

    return false
end

local function clearGhosts()
    WG.StopDrawAll(drawUnitShapeGL4OwnerId)
end

function widget:GameFrame(frame)
    local _, ctrl = spGetModKeyState()
    local _, cmdID = spGetActiveCommand()

    if ctrl and cmdID and cmdID == CMD_REPAIR and tableCount(destroyedBuildings) > 0 then
        framesRepairKeyHeld = framesRepairKeyHeld + 1
        -- Draw ghosts for all valid destroyed buildings
        for unitID, data in pairs(destroyedBuildings) do
            local x, y, z = data.position.x, data.position.y, data.position.z
            local opacity = math.max(0.25, 1 - (frame - data.frame) / 3000)

            -- fade in over first 15 frames
            if framesRepairKeyHeld <= 15 then
                opacity = opacity * (framesRepairKeyHeld / 15)
            end

            local existingGhost = ghosts[unitID]
                -- Convert heading to radians for correct rotation
                local facingRadians = data.facing * (2 * math.pi / 65536)
                local ghostHandle = WG.DrawUnitShapeGL4(data.unitDefID, x, y, z, facingRadians, opacity, myTeamID, 0.6, 0.3, existingGhost, drawUnitShapeGL4OwnerId)
            ghosts[unitID] = ghostHandle
        end
    else
        clearGhosts()
        framesRepairKeyHeld = 0
    end
end

function widget:Shutdown()
    clearGhosts()
end
