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
    - options
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
local spGetUnitDefID = Spring.GetUnitDefID

local drawUnitShapeGL4OwnerId = 1337
local CMD_REPAIR = CMD.REPAIR
local rebuildableUnitDefIDs = {}
local destroyedBuildings = {}
local myTeamID = spGetMyTeamID()
local ghosts = {}
local framesRepairKeyHeld = 0

local footprintCache = {}
local SQUARE_SIZE = 8
local BBOX_EPSILON = 0.1

local unitDefIDCanBuildCache = {}

local function headingToFacing(heading)
    if not heading then
        return 0
    end
    return math.floor((heading / 16384) + 0.5) % 4
end

local function getBuildableUnitDefIDs(unitDefID)
    local unitDef = UnitDefs[unitDefID]
    if not unitDef or not unitDef.buildOptions then
        return {}
    end
    local buildable = {}
    for id, u in pairs(unitDef.buildOptions) do
        local buildDef = UnitDefs[u]
        if buildDef then
            buildable[buildDef.id] = true
        end
    end

    return buildable
end

local function canUnitDefBuild(unitDefID, buildDefID)
    if not unitDefID or not buildDefID then
        return false
    end
    local cache = unitDefIDCanBuildCache[unitDefID]
    if not cache then
        cache = getBuildableUnitDefIDs(unitDefID)
        unitDefIDCanBuildCache[unitDefID] = cache
    end

    return cache[buildDefID] == true
end

local function canAnyUnitDefBuild(unitDefIDSet, buildDefID)
    if not buildDefID then
        return false
    end

    for unitDefID in pairs(unitDefIDSet) do
        if canUnitDefBuild(unitDefID, buildDefID) then
            return true
        end
    end

    return false
end

local function getFootprint(unitDefID, heading)
    local cache = footprintCache[unitDefID]
    if not cache then
        local unitDef = UnitDefs[unitDefID]
        if not unitDef then
            return
        end
        cache = {
            xsize = unitDef.xsize or ((unitDef.footprintX or 1) * 2),
            zsize = unitDef.zsize or ((unitDef.footprintZ or 1) * 2),
        }
        footprintCache[unitDefID] = cache
    end

    local xsize = cache.xsize
    local zsize = cache.zsize
    local facing = headingToFacing(heading)

    if facing == 1 or facing == 3 then
        xsize, zsize = zsize, xsize
    end

    local width = xsize * SQUARE_SIZE
    local depth = zsize * SQUARE_SIZE

    return width, depth, facing
end

local function computeBoundingBox(unitDefID, x, z, heading)
    if not x or not z then
        return
    end

    local width, depth, facing = getFootprint(unitDefID, heading)
    if not width or not depth then
        return
    end

    local halfWidth = width * 0.5
    local halfDepth = depth * 0.5

    return {
        minX = x - halfWidth,
        maxX = x + halfWidth,
        minZ = z - halfDepth,
        maxZ = z + halfDepth,
        facing = facing,
    }
end

local function ensureBoundingBox(unitID, data)
    if data and not data.bbox then
        local position = data.position
        if position then
            data.bbox = computeBoundingBox(data.unitDefID, position.x, position.z, data.facing)
        end
    end
    return data and data.bbox
end

local function boundingBoxesOverlap(a, b)
    if not a or not b then
        return false
    end
    if a.maxX <= b.minX + BBOX_EPSILON then return false end
    if a.minX >= b.maxX - BBOX_EPSILON then return false end
    if a.maxZ <= b.minZ + BBOX_EPSILON then return false end
    if a.minZ >= b.maxZ - BBOX_EPSILON then return false end
    return true
end

local function removeOverlappingDestroyed(bbox, skipUnitID)
    if not bbox then
        return
    end
    for otherUnitID, otherData in pairs(destroyedBuildings) do
        if otherUnitID ~= skipUnitID then
            local otherBox = ensureBoundingBox(otherUnitID, otherData)
            if otherBox and boundingBoxesOverlap(bbox, otherBox) then
                destroyedBuildings[otherUnitID] = nil
                if ghosts[otherUnitID] then
                    WG.StopDrawUnitShapeGL4(ghosts[otherUnitID])
                    ghosts[otherUnitID] = nil
                end
            end
        end
    end
end

local function tableCount(t)
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    return count
end

function widget:Initialize()
    for unitDefID, unitDef in pairs(UnitDefs) do
        if unitDef.isBuilding
            or unitDef.customParams.detonaterange or                              -- mines
            (unitDef.isBuilder and not unitDef.canMove and not unitDef.isFactory) -- nano
        then
            rebuildableUnitDefIDs[unitDefID] = true
        end
    end

    if WG and WG['gui_control_hints'] then
        WG['gui_control_hints'].addHint(CMD_REPAIR, true, false, false, false, "CTRL+DRAG", "Rebuild area", true, true)
        Spring.Echo("[Area Rebuild] Hint added to Control Hints")
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
        if not x or not z then
            return
        end
        local heading = spGetUnitHeading(unitID)
        local bbox = computeBoundingBox(unitDefID, x, z, heading)
        if not bbox then
            return
        end

        removeOverlappingDestroyed(bbox, unitID)
        destroyedBuildings[unitID] = {
            unitDefID = unitDefID,
            position = { x = x, y = y, z = z },
            facing = heading,
            frame = spGetGameFrame(),
            bbox = bbox
        }
    end
end

function widget:UnitFinished(unitID, unitDefID, unitTeam)
    if unitTeam ~= myTeamID then
        return
    end

    local x, y, z = spGetUnitPosition(unitID)
    if not x or not z then
        return
    end
    local heading = spGetUnitHeading(unitID)
    local bbox = computeBoundingBox(unitDefID, x, z, heading)
    if not bbox then
        return
    end

    removeOverlappingDestroyed(bbox, unitID)
end

function widget:CommandNotify(cmdID, cmdParams, cmdOptions)
    if cmdID == CMD_REPAIR and #cmdParams == 4 and cmdOptions and cmdOptions.ctrl then
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
            return true
        end

        -- Rebuild the buildings
        local selectedUnits = spGetSelectedUnits()
        if selectedUnits and #selectedUnits > 0 then
            local selectedUnitDefIDs = {}
            for i = 1, #selectedUnits do
                local unitDefID = spGetUnitDefID(selectedUnits[i])
                if unitDefID then
                    selectedUnitDefIDs[unitDefID] = true
                end
            end

            local filteredOrders = {}
            for _, order in ipairs(orders) do
                local targetUnitDefID = -order[1]
                if canAnyUnitDefBuild(selectedUnitDefIDs, targetUnitDefID) then
                    order.targetUnitDefID = targetUnitDefID
                    table.insert(filteredOrders, order)
                end
            end

            if #filteredOrders == 0 then
                return true
            end

            if not cmdOptions.shift then
                spGiveOrderToUnitArray(selectedUnits, CMD.STOP)
            end

            for _, order in ipairs(filteredOrders) do
                spGiveOrderToUnitArray(selectedUnits, order[1], order[2], { "shift" })
            end

            -- remove the destroyedBuildings and ghosts for the rebuilt buildings
            for _, order in ipairs(filteredOrders) do
                local targetUnitDefID = order.targetUnitDefID or -order[1]
                local params = order[2]
                for destroyedUnitID, data in pairs(destroyedBuildings) do
                    if data.unitDefID == targetUnitDefID
                        and data.position.x == params[1]
                        and data.position.y == params[2]
                        and data.position.z == params[3] then
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
            return true
        end
    end

    return false
end

local function clearGhosts()
    WG.StopDrawAll(drawUnitShapeGL4OwnerId)
end

local function cleanOld(frame)
    for unitID, data in pairs(destroyedBuildings) do
        if frame - data.frame > 3000 then
            destroyedBuildings[unitID] = nil
            if ghosts[unitID] then
                WG.StopDrawUnitShapeGL4(ghosts[unitID])
                ghosts[unitID] = nil
            end
        end
    end
end

function widget:GameFrame(frame)
    local _, ctrl = spGetModKeyState()
    local _, cmdID = spGetActiveCommand()

    if frame % 300 == 0 then
        cleanOld(frame)
    end

    if ctrl and cmdID and cmdID == CMD_REPAIR and tableCount(destroyedBuildings) > 0 then
        framesRepairKeyHeld = framesRepairKeyHeld + 1
        -- Draw ghosts for all valid destroyed buildings
        for unitID, data in pairs(destroyedBuildings) do
            local x, y, z = data.position.x, data.position.y, data.position.z
            local maxOpacity = math.min(1, framesRepairKeyHeld / 15)
            local minimumOpacity = 0.2
            local ageBasedOpacity = math.max(minimumOpacity, 1 - (frame - data.frame) / 3000)
            local opacity = math.min(maxOpacity, ageBasedOpacity)

            local existingGhost = ghosts[unitID]
            -- Convert heading to radians for correct rotation
            local facingRadians = data.facing * (2 * math.pi / 65536)
            local ghostHandle = WG.DrawUnitShapeGL4(data.unitDefID, x, y, z, facingRadians, opacity, myTeamID, 0.6, 0.3,
            existingGhost, drawUnitShapeGL4OwnerId)
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
