
local widget = widget ---@type Widget

-- Engine-provided globals: Spring, gl, GL, WG
-- luacheck: globals Spring WG gl GL KEYSYMS UnitDefs widget

-- Forward declare globals for static analyzers (they already exist at runtime)
Spring = Spring
WG = WG
gl = gl
GL = GL
KEYSYMS = KEYSYMS or {}
UnitDefs = UnitDefs

function widget:GetInfo()
    return {
        name = "Build Snap (all buildings)",
        desc = "Snaps building placement to the nearest valid build grid point (within a small search radius). Hold Alt to temporarily disable.",
        author = "uBdead (based on Extractor Snap patterns) by Hobo Joe, based on work by Niobium and Floris",
        date = "2025-08-31",
        license = "GNU GPL, v2 or later",
        layer = 0,
        enabled = true
    }
end

--------------------------------------------------
-- Locals / engine references
--------------------------------------------------

local spGetActiveCommand = Spring.GetActiveCommand
local spGetMouseState    = Spring.GetMouseState
local spTraceScreenRay   = Spring.TraceScreenRay
local spPos2BuildPos     = Spring.Pos2BuildPos
local spTestBuildOrder   = Spring.TestBuildOrder
local spGetBuildFacing   = Spring.GetBuildFacing
local spGetModKeyState   = Spring.GetModKeyState
local spGiveOrder        = Spring.GiveOrder
local spSetActiveCommand = Spring.SetActiveCommand

--------------------------------------------------
-- Config
--------------------------------------------------

local GRID_STEP = 8              -- Spring build grid is in multiples of 8 map units
local MAX_RADIUS_STEPS = 10      -- How far (in GRID_STEP steps) to search outward (80 elmos)
local USE_SPIRAL = true          -- Spiral search vs simple snap-to-nearest
local MIN_DIST_SNAP_SQ = 1       -- If already basically at snapped position, don't override

--------------------------------------------------
-- State
--------------------------------------------------

local activeCmdID
local buildingDefID
local cursorPos        -- current raw build-aligned cursor position (table{x,y,z})
local snappedPos       -- snapped valid target position (table{x,y,z})
local ghostShape
local ghostActiveHandle
local lastFacing

WG.BuildSnap = WG.BuildSnap or {}

--------------------------------------------------
-- Utility
--------------------------------------------------

local function sqr(x) return x * x end

local function distSq(a, b)
    return sqr(a.x - b.x) + sqr(a.y - b.y) + sqr(a.z - b.z)
end

local function roundToGrid(v)
    return math.floor((v + GRID_STEP * 0.5) / GRID_STEP) * GRID_STEP
end

local function isBuildable(uDefID, x, y, z, facing)
    local r = spTestBuildOrder(uDefID, x, y, z, facing)
    return r and r ~= 0
end

-- Spiral iterator around a center grid cell.
local function findNearestValid(uDefID, cx, cy, cz, facing)
    -- First try centre itself
    if isBuildable(uDefID, cx, cy, cz, facing) then
        return { x = cx, y = cy, z = cz }
    end
    local best
    local bestDistSq = math.huge
    if not USE_SPIRAL then return nil end
    local xStep, zStep = 0, 0
    local dx, dz = 0, -1
    local max = (MAX_RADIUS_STEPS * 2 + 1) ^ 2
    local startX = cx
    local startZ = cz
    for i = 1, max do
        local gx = startX + xStep * GRID_STEP
        local gz = startZ + zStep * GRID_STEP
        local gy = Spring.GetGroundHeight(gx, gz)
        if math.abs(xStep) <= MAX_RADIUS_STEPS and math.abs(zStep) <= MAX_RADIUS_STEPS then
            if isBuildable(uDefID, gx, gy, gz, facing) then
                local d2 = (gx - cx) * (gx - cx) + (gz - cz) * (gz - cz)
                if d2 < bestDistSq then
                    bestDistSq = d2
                    best = { x = gx, y = gy, z = gz }
                    if d2 == 0 then break end
                end
            end
        end
        if xStep == zStep or (xStep < 0 and xStep == -zStep) or (xStep > 0 and xStep == 1 - zStep) then
            dx, dz = -dz, dx
        end
        xStep = xStep + dx
        zStep = zStep + dz
        if best and bestDistSq <= (GRID_STEP * GRID_STEP) then
            -- close enough, stop early
            break
        end
    end
    return best
end

local function clear()
    if ghostActiveHandle and WG.StopDrawUnitShapeGL4 then
        WG.StopDrawUnitShapeGL4(ghostActiveHandle)
    end
    ghostActiveHandle = nil
    ghostShape = nil
    activeCmdID = nil
    buildingDefID = nil
    cursorPos = nil
    snappedPos = nil
    WG.BuildSnap.position = nil
end

-- Adapted from extractor snap: handle grid menu interactions if present
local endShift = false
local function handleBuildMenu(shift)
    endShift = shift
    if not shift then
        spSetActiveCommand(0)
    end
    local grid = WG["gridmenu"]
    if not grid or not grid.clearCategory or not grid.getAlwaysReturn or not grid.setCurrentCategory then
        return
    end
    if (not shift and not grid.getAlwaysReturn()) then
        grid.clearCategory()
    elseif grid.getAlwaysReturn() then
        grid.setCurrentCategory(nil)
    end
end

--------------------------------------------------
-- Core Update Loop
--------------------------------------------------

function widget:Update()
    local _, cmdID = spGetActiveCommand()
    activeCmdID = cmdID
    if not cmdID or cmdID >= 0 then
        clear()
        return
    end

    buildingDefID = -cmdID
    -- Skip extractors (handled by dedicated extractor snap widget)
    local uDef = UnitDefs and UnitDefs[buildingDefID]
    if uDef and uDef.extractsMetal and uDef.extractsMetal > 0 then
        clear()
        return
    end
    local mx, my = spGetMouseState()
    local _, worldPos = spTraceScreenRay(mx, my, true)
    if not worldPos then
        clear()
        return
    end

    local alt, _, _, shift = spGetModKeyState() -- alt, ctrl, meta, shift

    local facing = spGetBuildFacing()
    lastFacing = facing
        local bx, by, bz = spPos2BuildPos(buildingDefID, worldPos[1], worldPos[2], worldPos[3])
    cursorPos = { x = bx, y = by, z = bz }

    if alt then
        -- Snapping disabled while alt held
        snappedPos = nil
        WG.BuildSnap.position = nil
        if ghostActiveHandle then
            WG.StopDrawUnitShapeGL4(ghostActiveHandle)
            ghostActiveHandle = nil
        end
        return
    end

    -- Compute grid-aligned candidate
    local gx = roundToGrid(bx)
    local gz = roundToGrid(bz)
    local gy = Spring.GetGroundHeight(gx, gz)

    local best
    if isBuildable(buildingDefID, gx, gy, gz, facing) then
        best = { x = gx, y = gy, z = gz }
    else
        best = findNearestValid(buildingDefID, gx, gy, gz, facing)
    end

    if best then
        snappedPos = best
        WG.BuildSnap.position = best
        if distSq(snappedPos, cursorPos) <= MIN_DIST_SNAP_SQ then
            -- no visual diff
            if ghostActiveHandle then
                WG.StopDrawUnitShapeGL4(ghostActiveHandle)
                ghostActiveHandle = nil
            end
        else
            -- prepare ghost shape
            ghostShape = { buildingDefID, best.x, best.y, best.z, facing, 0 }
            if WG.DrawUnitShapeGL4 then
                if ghostActiveHandle then
                    WG.StopDrawUnitShapeGL4(ghostActiveHandle)
                    ghostActiveHandle = nil
                end
                ghostActiveHandle = WG.DrawUnitShapeGL4(ghostShape[1], ghostShape[2], ghostShape[3], ghostShape[4], ghostShape[5] * (math.pi/2), 0.66, ghostShape[6], 0.15, 0.3)
            end
        end
    else
        snappedPos = nil
        WG.BuildSnap.position = nil
        if ghostActiveHandle then
            WG.StopDrawUnitShapeGL4(ghostActiveHandle)
            ghostActiveHandle = nil
        end
    end
end

--------------------------------------------------
-- Input
--------------------------------------------------

function widget:MousePress(x, y, button)
    if button ~= 1 then return end
    if not buildingDefID or not snappedPos then return end
    if not cursorPos then return end
    if not activeCmdID or activeCmdID >= 0 then return end

    -- If snapping changed the position meaningfully, issue order manually and eat click
    local d2 = distSq(cursorPos, snappedPos)
    if d2 > MIN_DIST_SNAP_SQ then
    local _, _, _, shift = spGetModKeyState()
    shift = Spring.GetInvertQueueKey() and (not shift) or shift
        local opts = shift and { "shift" } or {}
        spGiveOrder(activeCmdID, { snappedPos.x, snappedPos.y, snappedPos.z, lastFacing }, opts)
        handleBuildMenu(shift)
        return true
    end
end

function widget:KeyRelease(code)
    if endShift and (code == KEYSYMS.LSHIFT or code == KEYSYMS.RSHIFT) then
        spSetActiveCommand(0)
        endShift = false
    end
end

--------------------------------------------------
-- Drawing
--------------------------------------------------

local function MakeLine(x1,y1,z1,x2,y2,z2)
    gl.Vertex(x1,y1,z1)
    gl.Vertex(x2,y2,z2)
end

function widget:DrawWorld()
    if not cursorPos or not snappedPos then return end
    if distSq(cursorPos, snappedPos) <= MIN_DIST_SNAP_SQ then return end
    gl.DepthTest(false)
    gl.LineWidth(2)
    gl.Color(0.3, 1, 0.3, 0.45)
    ---@diagnostic disable-next-line: param-type-mismatch
    gl.BeginEnd(GL.LINE_STRIP, MakeLine, cursorPos.x, cursorPos.y, cursorPos.z, snappedPos.x, snappedPos.y, snappedPos.z)
    gl.LineWidth(1)
    gl.DepthTest(true)
end

--------------------------------------------------
-- Life cycle
--------------------------------------------------

function widget:Shutdown()
    clear()
end


