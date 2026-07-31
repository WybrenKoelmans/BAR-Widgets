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
        desc =
        "Snaps building placement to the nearest valid build grid point (within a small search radius). Hold Alt to temporarily disable.",
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
local spGetSelectedUnits = Spring.GetSelectedUnits
local spGetUnitCommands  = Spring.GetUnitCommands
local spGiveOrderToUnit  = Spring.GiveOrderToUnit
local spGetUnitPosition  = Spring.GetUnitPosition
local spGetFeaturePosition = Spring.GetFeaturePosition
local spGetUnitDefID     = Spring.GetUnitDefID
local spIsUnitAllied     = Spring.IsUnitAllied
local spGetUnitBuildFacing = Spring.GetUnitBuildFacing
local spSetBuildFacing   = Spring.SetBuildFacing

--------------------------------------------------
-- Config
--------------------------------------------------

local GRID_STEP          = 8 -- Spring build grid is in multiples of 8 map units
local MAX_RADIUS_STEPS   = 10 -- How far (in GRID_STEP steps) to search outward (80 elmos)
local USE_SPIRAL         = true -- Spiral search vs simple snap-to-nearest
local MIN_DIST_SNAP_SQ   = 1 -- If already basically at snapped position, don't override
local MAGNET_MAX_STEPS   = 48 -- axis march limit for the same-building magnet (384 elmos)
local MAX_DRAG_CELLS     = 30 -- per-axis cap for magnet drag rows/grids

--------------------------------------------------
-- State
--------------------------------------------------

local activeCmdID
local buildingDefID
local cursorPos  -- current raw build-aligned cursor position (table{x,y,z})
local snappedPos -- snapped valid target position (table{x,y,z})
local ghostShape
local ghostActiveHandle
local lastFacing
local magnetTarget -- unitID of same-def building under cursor (magnet mode)
local magnetLastTarget -- last magnet unitID (facing matched once per acquisition)
-- Magnet drag takeover: on press we cancel the engine command (so NO default
-- blueprint draws anywhere) and own the whole drag — live ghosts show the true
-- row/grid, orders issued on release.
local takeover -- { defID, facing, anchor, positions, ghosts, sig, lastMx/My/Alt }

-- NOTE: lobbies with allowunitcontrolwidgets=false evict unit-control user
-- widgets at load, so there is nothing to guard against here — where the widget
-- loads at all, Spring.GiveOrder* works.

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
    magnetTarget = nil
    magnetLastTarget = nil
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
-- Same-building magnet helpers
--------------------------------------------------

-- Slot on the target building's center axis: lock the perpendicular coordinate
-- to the target's center (grid-legal since same def + same facing) and march
-- along the dominant axis, away from the center, until buildable.
local function findAxisSlot(uDefID, tx, tz, dx, dz, facing)
    local horizontal = math.abs(dx) >= math.abs(dz)
    local dir = ((horizontal and dx or dz) >= 0) and 1 or -1
    for i = 0, MAGNET_MAX_STEPS do
        local wx, wz
        if horizontal then
            wx, wz = tx + dx + dir * i * GRID_STEP, tz
        else
            wx, wz = tx, tz + dz + dir * i * GRID_STEP
        end
        local sx, _, sz = spPos2BuildPos(uDefID, wx, Spring.GetGroundHeight(wx, wz), wz, facing)
        if horizontal then sz = tz else sx = tx end
        local sy = Spring.GetGroundHeight(sx, sz)
        if isBuildable(uDefID, sx, sy, sz, facing) then
            return { x = sx, y = sy, z = sz }
        end
    end
    return nil
end

-- Shared tail of the update loop: publish the snap result + manage the ghost
local function applyBest(best, facing)
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
                ghostActiveHandle = WG.DrawUnitShapeGL4(ghostShape[1], ghostShape[2], ghostShape[3], ghostShape[4], ghostShape[5] * (math.pi / 2), 0.66, ghostShape[6], 0.15, 0.3)
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

local function EndTakeover()
    if not takeover then return end
    if WG.StopDrawUnitShapeGL4 then
        for i = 1, #takeover.ghosts do
            WG.StopDrawUnitShapeGL4(takeover.ghosts[i])
        end
    end
    takeover = nil
end

-- Recompute the dragged row/grid from the aligned anchor to the current mouse:
-- no Alt = line along the dominant drag axis, Alt = 2D grid. Spacing = exact
-- footprint size (xsize/zsize * 8 elmos, swapped for odd facings), so every
-- cell stays flush AND on the magnet axis. Ghosts rebuilt only on change.
local function UpdateTakeover(force)
    local t = takeover
    if not t then return end
    local mx2, my2 = spGetMouseState()
    local alt = spGetModKeyState()
    if not force and t.lastMx == mx2 and t.lastMy == my2 and t.lastAlt == alt then
        return
    end
    t.lastMx, t.lastMy, t.lastAlt = mx2, my2, alt

    local _, wp = spTraceScreenRay(mx2, my2, true)
    local ex = wp and wp[1] or t.anchor.x
    local ez = wp and wp[3] or t.anchor.z
    local ud = UnitDefs[t.defID]
    local fx = ud.xsize * 8 -- footprint cell = 8 elmos
    local fz = ud.zsize * 8
    if t.facing % 2 == 1 then
        fx, fz = fz, fx
    end
    local dx = ex - t.anchor.x
    local dz = ez - t.anchor.z
    local nx = math.min(MAX_DRAG_CELLS, math.floor(math.abs(dx) / fx + 0.5))
    local nz = math.min(MAX_DRAG_CELLS, math.floor(math.abs(dz) / fz + 0.5))
    if not alt then
        -- line mode: dominant axis only
        if math.abs(dx) >= math.abs(dz) then nz = 0 else nx = 0 end
    end
    local sx = (dx >= 0) and 1 or -1
    local sz = (dz >= 0) and 1 or -1

    local positions = {}
    for i = 0, nx do
        for j = 0, nz do
            local px = t.anchor.x + i * sx * fx
            local pz = t.anchor.z + j * sz * fz
            local py = Spring.GetGroundHeight(px, pz)
            if isBuildable(t.defID, px, py, pz, t.facing) then
                positions[#positions + 1] = { x = px, y = py, z = pz }
            end
        end
    end
    t.positions = positions

    local sig = table.concat({ #positions, nx, nz, sx, sz, alt and 1 or 0 }, ":")
    if #positions > 0 then
        sig = sig .. ":" .. positions[1].x .. "," .. positions[1].z
            .. ":" .. positions[#positions].x .. "," .. positions[#positions].z
    end
    if sig ~= t.sig then
        t.sig = sig
        if WG.StopDrawUnitShapeGL4 then
            for i = 1, #t.ghosts do
                WG.StopDrawUnitShapeGL4(t.ghosts[i])
            end
        end
        t.ghosts = {}
        if WG.DrawUnitShapeGL4 then
            for i = 1, #positions do
                local p = positions[i]
                t.ghosts[#t.ghosts + 1] = WG.DrawUnitShapeGL4(t.defID, p.x, p.y, p.z, t.facing * (math.pi / 2), 0.66, 0, 0.15, 0.3)
            end
        end
    end
end

--------------------------------------------------
-- Core Update Loop
--------------------------------------------------

function widget:GameFrame(frame)
    if frame % 5 ~= 3 then
        return
    end

    -- during a magnet takeover drag the active command is cancelled and our
    -- ghosts are authoritative — freeze the normal update loop
    if takeover then
        return
    end

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

    -- Same-building magnet: hovering an allied FINISHED-or-not building of the
    -- SAME type aligns the placement to its center axis and matches its facing,
    -- so dragged rows/grids continue it perfectly. Checked BEFORE the Alt
    -- bail-out (Shift+Alt grid drags must keep the magnet). In this mode the
    -- press is NOT eaten — the engine anchors its native drag and CommandNotify
    -- translates the resulting orders.
    magnetTarget = nil
    local hitKind, hitUnit = spTraceScreenRay(mx, my, false)
    if hitKind == "unit" and hitUnit then
        local hitDefID = spGetUnitDefID(hitUnit)
        if hitDefID == buildingDefID and spIsUnitAllied(hitUnit) then
            local ttx, _, ttz = spGetUnitPosition(hitUnit)
            if ttx then
                if magnetLastTarget ~= hitUnit then
                    magnetLastTarget = hitUnit
                    local tf = spGetUnitBuildFacing(hitUnit)
                    if tf and tf ~= facing then
                        spSetBuildFacing(tf)
                        facing = tf
                        lastFacing = tf
                    end
                end
                local best = findAxisSlot(buildingDefID, ttx, ttz, bx - ttx, bz - ttz, facing)
                if best then
                    magnetTarget = hitUnit
                    applyBest(best, facing)
                    return
                end
            end
        end
    else
        magnetLastTarget = nil
    end

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

    applyBest(best, facing)
end

--------------------------------------------------
-- Input
--------------------------------------------------

-- Queue-insert support: our swallowed click + direct GiveOrder bypasses the stock
-- CommandInsert widget (CommandNotify never fires for widget-issued orders), so
-- Space-insert must be reproduced here or a snapped placement wipes the queue.
-- Helpers mirror cmd_commandinsert.lua.
local function GetUnitOrFeaturePosition(id)
    if id < Game.maxUnits then
        return spGetUnitPosition(id)
    end
    return spGetFeaturePosition(id - Game.maxUnits)
end

local function GetCommandPos(cmd)
    local id, params = cmd.id, cmd.params
    if id < 0 or id == CMD.MOVE or id == CMD.REPAIR or id == CMD.RECLAIM or id == CMD.RESURRECT
        or id == CMD.DGUN or id == CMD.GUARD or id == CMD.FIGHT or id == CMD.ATTACK then
        if #params >= 3 then
            return params[1], params[2], params[3]
        elseif #params >= 1 then
            return GetUnitOrFeaturePosition(params[1])
        end
    end
    return -10, -10, -10
end

-- Issue a snapped/translated build order with full modifier fidelity. Orders
-- issued by widgets bypass CommandNotify, so with meta (Space) held we must
-- reproduce stock CommandInsert ourselves or the queue gets wiped.
local function issueOrder(cmdID, params, alt, ctrl, meta, shift)
    if meta then
        local opt = 0
        if alt then opt = opt + CMD.OPT_ALT end
        if ctrl then opt = opt + CMD.OPT_CTRL end
        if shift then opt = opt + CMD.OPT_SHIFT end
        if not shift then
            -- Space alone: insert at the FRONT of the queue (CommandInsert's
            -- no-shift branch); the rest of the queue survives
            spGiveOrder(CMD.INSERT, { 0, cmdID, opt, unpack(params) }, { "alt" })
        else
            -- Space+Shift: insert between the two queued commands closest to
            -- the new position, per selected unit (CommandInsert's walk)
            local cx, cy, cz = params[1], params[2], params[3]
            local units = spGetSelectedUnits()
            for i = 1, #units do
                local unitID = units[i]
                local commands = spGetUnitCommands(unitID, 100)
                local px, py, pz = spGetUnitPosition(unitID)
                local minDlen = math.huge
                local insertPos = 0
                for j = 1, #commands do
                    local px2, py2, pz2 = GetCommandPos(commands[j])
                    if px2 and px2 > -1 then
                        -- detour cost of visiting the new spot between j-1 and j
                        local dlen = math.sqrt(sqr(px2 - cx) + sqr(py2 - cy) + sqr(pz2 - cz))
                            + math.sqrt(sqr(px - cx) + sqr(py - cy) + sqr(pz - cz))
                            - math.sqrt(sqr(px2 - px) + sqr(py2 - py) + sqr(pz2 - pz))
                        if dlen < minDlen then
                            minDlen = dlen
                            insertPos = j
                        end
                        px, py, pz = px2, py2, pz2
                    end
                end
                -- appending at the end may beat inserting anywhere
                local dlen = math.sqrt(sqr(px - cx) + sqr(py - cy) + sqr(pz - cz))
                if dlen < minDlen then
                    spGiveOrderToUnit(unitID, cmdID, params, { "shift" })
                else
                    spGiveOrderToUnit(unitID, CMD.INSERT, { insertPos - 1, cmdID, opt, unpack(params) }, { "alt" })
                end
            end
        end
    else
        spGiveOrder(cmdID, params, shift and { "shift" } or {})
    end
end

function widget:MousePress(x, y, button)
    -- any other mouse button during a magnet drag cancels it (nothing issued)
    if takeover then
        EndTakeover()
        return true
    end
    if button ~= 1 then return end
    if not buildingDefID or not snappedPos then return end
    if not cursorPos then return end
    if not activeCmdID or activeCmdID >= 0 then return end

    -- Magnet mode: take over the whole drag. The engine command is cancelled so
    -- NO default blueprint draws anywhere — our ghosts are the only preview and
    -- they show exactly what will be built. Orders are issued on release.
    -- Everything recomputed fresh here — GameFrame state is up to 5 frames old.
    if magnetTarget then
        local _, wp = spTraceScreenRay(x, y, true)
        local ttx, _, ttz = spGetUnitPosition(magnetTarget)
        if wp and ttx then
            local f = spGetBuildFacing()
            local rx, _, rz = spPos2BuildPos(buildingDefID, wp[1], wp[2], wp[3], f)
            local best = findAxisSlot(buildingDefID, ttx, ttz, rx - ttx, rz - ttz, f)
            if best then
                takeover = {
                    defID = buildingDefID,
                    facing = f,
                    anchor = best,
                    positions = { best },
                    ghosts = {},
                    sig = "",
                }
                -- drop the single hover ghost; the takeover draws its own set
                if ghostActiveHandle and WG.StopDrawUnitShapeGL4 then
                    WG.StopDrawUnitShapeGL4(ghostActiveHandle)
                    ghostActiveHandle = nil
                end
                spSetActiveCommand(0)
                UpdateTakeover(true)
                return true
            end
        end
        return
    end

    -- If snapping changed the position meaningfully, issue order manually and eat click
    local d2 = distSq(cursorPos, snappedPos)
    if d2 > MIN_DIST_SNAP_SQ then
        local alt, ctrl, meta, shift = spGetModKeyState()
        shift = Spring.GetInvertQueueKey() and (not shift) or shift
        issueOrder(activeCmdID, { snappedPos.x, snappedPos.y, snappedPos.z, lastFacing }, alt, ctrl, meta, shift)
        handleBuildMenu(shift)
        return true
    end
end

-- Magnet drag release: issue the previewed lattice. First order honors the
-- live shift state, the rest always queue (a multi-placement makes no sense
-- unqueued); meta reproduces CommandInsert via issueOrder as everywhere else.
function widget:MouseRelease(x, y, button)
    if not takeover or button ~= 1 then return end
    UpdateTakeover(true) -- final refresh at the release position
    local t = takeover
    local alt, ctrl, meta, shift = spGetModKeyState()
    shift = Spring.GetInvertQueueKey() and (not shift) or shift
    for i = 1, #t.positions do
        local p = t.positions[i]
        issueOrder(-t.defID, { p.x, p.y, p.z, t.facing }, alt, ctrl, meta, shift or (i > 1))
    end
    EndTakeover()
    if shift then
        -- we cancelled the engine command at press; restore it so shift-chained
        -- placement keeps working
        local idx = Spring.GetCmdDescIndex(-t.defID)
        if idx and idx > 0 then
            spSetActiveCommand(idx, 1, true, false, alt, ctrl, false, false)
        end
    end
    handleBuildMenu(shift)
end

function widget:Update()
    if takeover then
        UpdateTakeover()
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
local function MakeLine(x1, y1, z1, x2, y2, z2)
    gl.Vertex(x1, y1, z1)
    gl.Vertex(x2, y2, z2)
end

function widget:DrawWorld()
    if takeover then return end -- ghosts are the only preview during a magnet drag
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
    EndTakeover()
    clear()
end
