local SELECT_RADIUS = 400 -- Adjust the radius as needed 
local DRAG_THRESHOLD = 5 -- max pixels the mouse may move before a left-click counts as a drag-select instead of a squad click
local DOUBLE_CLICK_TIME = 0.1 -- seconds; two clicks within this window count as a double-click and must not select a squad
local DOUBLE_CLICK_RADIUS = 8 -- max pixels between the two clicks for them to count as a double-click


local widget = widget ---@type Widget

function widget:GetInfo()
    return {
        name = "Squads",
        desc = "Selecting a group of units will create a squad, which can be selected as a whole by clicking near them.",
        author = "uBdead (idea and shader: Baldric, yyyy)",
        date = "June 2026",
        license = "GNU GPL, v2 or later",
        layer = 0,
        enabled = true
    }
end

local squadIDByUnitID = {}
local unitIDsBySquadID = {}
local squadSeedBySquadID = {} -- squadID -> golden-ratio phase offset for hull pulse animation
local hoverBlendBySquadID = {} -- squadID -> 0..1 eased hover amount
local nextSquadSeed = 0
local nextSquadNum = 0 -- monotonic counter for collision-free squad IDs
local selectedUnitSet = {} -- unitID -> true for the units currently selected

-- Pending left-click state, used to distinguish a squad click from a drag-select.
local pendingSquadID = nil -- squad the press started on, selected on release if it stays a click
local pendingSquadWasSelected = false -- whether that squad was already fully selected at press time
local pendingSquadShift = false -- whether shift was held at press time (join squads instead of select)
local pendingPressX = 0 -- screen X where the left button went down
local pendingPressY = 0 -- screen Y where the left button went down
local pendingIsDrag = false -- set once the mouse moves past DRAG_THRESHOLD while held

-- Deferred squad selection, held back briefly so a second click (double-click) can cancel it.
local pendingCommitSquadID = nil -- squad to select once the double-click window elapses
local pendingCommitWasSelected = false -- whether the committed squad was already selected at press time
local pendingCommitShift = false -- whether shift was held when the committed click was released
local pendingCommitTime = nil -- timer captured when the click was released
local pendingCommitX = 0 -- screen X of the released click
local pendingCommitY = 0 -- screen Y of the released click

-------------------------------------------------------------------------------
-- Convex hull config (ported from squad-selection.lua)
-------------------------------------------------------------------------------

local config = {
    convexHullPadding = 60, -- space (in elmos) between the units and the hull boundary
    convexHullArcResolution = 0.4, -- angle each chord of the rounded corners spans, in radians; smaller = smoother but more expensive
    convexHullFillOpacity = 0.08,
    convexHullBorderOpacity = 0.15,
    convexHullBorderThickness = 2,
    hullPulseAmplitude = 0.25, -- breathing pulse amplitude on hull alpha
    hullPulseRate = 1.5, -- breathing pulse rate; period ~= 2*pi / rate seconds
    hoverFillOpacityBonus = 0.22, -- extra fill opacity at full hover for the squad under the mouse
    hoverBorderOpacityBonus = 0.5, -- extra border opacity at full hover for the squad under the mouse
    hoverBorderThickness = 3.5, -- border thickness at full hover for the squad under the mouse
    hoverEaseSpeed = 4, -- hover blend speed (1/seconds); higher = faster ease in/out
}

-------------------------------------------------------------------------------
-- Localized Spring / gl API
-------------------------------------------------------------------------------

local spGetMyTeamID = Spring.GetMyTeamID
local spGetTeamColor = Spring.GetTeamColor
local spGetUnitDefID = Spring.GetUnitDefID
local spGetUnitPosition = Spring.GetUnitPosition
local spGetGroundHeight = Spring.GetGroundHeight
local spIsGUIHidden = Spring.IsGUIHidden
local spIsSphereInView = Spring.IsSphereInView
local spGetTimer = Spring.GetTimer
local spDiffTimers = Spring.DiffTimers
local spGetMouseState = Spring.GetMouseState
local spTraceScreenRay = Spring.TraceScreenRay
local spGetUnitsInCylinder = Spring.GetUnitsInCylinder
local spGetActiveCommand = Spring.GetActiveCommand
local spGetModKeyState = Spring.GetModKeyState

local glColor = gl.Color
local glDepthTest = gl.DepthTest
local glLineWidth = gl.LineWidth
local glCreateShader = gl.CreateShader
local glDeleteShader = gl.DeleteShader
local glUseShader = gl.UseShader
local glGetUniformLocation = gl.GetUniformLocation
local glUniform = gl.Uniform
local glGetVBO = gl.GetVBO
local glGetVAO = gl.GetVAO

local teamColor = {1, 1, 1}

-- Pre-computed lookup of which unit defs are allowed in a squad.
-- A unit qualifies only if it is a ground-moving unit: it can move, has a
-- non-zero move speed, and cannot fly. Indexed by unitDefID -> true.
local canBeInSquad = {}
for unitDefID, ud in pairs(UnitDefs) do
    if ud.canMove and ud.speed > 0 and not ud.canFly then
        canBeInSquad[unitDefID] = true
    end
end

-- Returns true if the given unit is eligible to be part of a squad.
local function unitCanBeInSquad(unitID)
    local unitDefID = spGetUnitDefID(unitID)
    return unitDefID ~= nil and canBeInSquad[unitDefID] == true
end

local function disposeUnit(unitID)
    --Spring.Echo("Disposing unit " .. unitID .. " from squads")
    local squadID = squadIDByUnitID[unitID]
    if squadID then
        -- Remove the unit from the squad
        local unitIDs = unitIDsBySquadID[squadID]
        
        if (not unitIDs) then return end

        for i, id in ipairs(unitIDs) do
            if id == unitID then
                table.remove(unitIDs, i)
                break
            end
        end

        squadIDByUnitID[unitID] = nil

        -- A squad needs at least 2 units; if only one (or none) remains, disband
        -- it and clear the leftover unit's mapping too.
        if #unitIDs <= 1 then
            for _, id in ipairs(unitIDs) do
                squadIDByUnitID[id] = nil
            end
            unitIDsBySquadID[squadID] = nil
            squadSeedBySquadID[squadID] = nil
            hoverBlendBySquadID[squadID] = nil
        end
    end
end

local function createSquad(unitIDs)
    local squadID = "squad_" .. nextSquadNum
    nextSquadNum = nextSquadNum + 1
    local squadUnits = {}
    unitIDsBySquadID[squadID] = squadUnits
    squadSeedBySquadID[squadID] = nextSquadSeed * 0.6180339887
    nextSquadSeed = nextSquadSeed + 1

    for _, unitID in ipairs(unitIDs) do
        disposeUnit(unitID) -- Ensure the unit is not already in another squad
        squadIDByUnitID[unitID] = squadID
        squadUnits[#squadUnits + 1] = unitID
        --Spring.Echo("Unit " .. unitID .. " added to squad " .. squadID)
    end

    return squadID
end

-- Returns true when every unit of the squad is part of the current selection.
local function isSquadSelected(squadID)
    local unitIDs = unitIDsBySquadID[squadID]
    if not unitIDs or #unitIDs == 0 then
        return false
    end
    for i = 1, #unitIDs do
        if not selectedUnitSet[unitIDs[i]] then
            return false
        end
    end
    return true
end

local function selectSquad(squadID, wasSelected, shift)
    local unitIDs = unitIDsBySquadID[squadID]
    if not unitIDs then
        return
    end

    -- Shift+clicking another squad joins it with the current selection (which may
    -- itself be one or more squads). Selecting the combined units triggers
    -- SelectionChanged, which merges all eligible units into a single squad.
    if shift then
        local combined = {}
        local seen = {}
        for selectedID in pairs(selectedUnitSet) do
            if not seen[selectedID] then
                seen[selectedID] = true
                combined[#combined + 1] = selectedID
            end
        end
        for i = 1, #unitIDs do
            local id = unitIDs[i]
            if not seen[id] then
                seen[id] = true
                combined[#combined + 1] = id
            end
        end
        --Spring.Echo("Joining squad: " .. squadID)
        Spring.SelectUnitArray(combined, false)
        return
    end

    -- Clicking the squad that was already fully selected when the press began
    -- toggles it off: clear the selection instead of re-selecting the same units.
    -- We rely on the at-press state (not the live selection) because the engine's
    -- native click handling may have already changed the selection by now.
    if wasSelected then
        --Spring.Echo("Deselecting squad: " .. squadID)
        Spring.SelectUnitArray({}, false)
        return
    end

    --Spring.Echo("Selecting squad: " .. squadID)
    --Spring.Echo("Units in squad: " .. #unitIDs)
    Spring.SelectUnitArray(unitIDs, false) -- Replace current selection with squad units
end

-- Returns the squadID that a click at the current mouse position would select,
-- mirroring the logic in widget:MousePress, or nil when nothing would select.
local function getSquadUnderMouse()
    if spGetActiveCommand() ~= 0 then
        return nil
    end
    local mx, my = spGetMouseState()
    if not mx then
        return nil
    end
    local traceType, coords = spTraceScreenRay(mx, my, true)
    if traceType ~= "ground" or not coords then
        return nil
    end
    local units = spGetUnitsInCylinder(coords[1], coords[3], SELECT_RADIUS)
    local closestSquadID = nil
    local closestDistSq = math.huge
    for i = 1, #units do
        local unitID = units[i]
        local squadID = squadIDByUnitID[unitID]
        if squadID then
            local ux, _, uz = spGetUnitPosition(unitID)
            if ux then
                local dx = ux - coords[1]
                local dz = uz - coords[3]
                local distSq = dx * dx + dz * dz
                if distSq < closestDistSq then
                    closestDistSq = distSq
                    closestSquadID = squadID
                end
            end
        end
    end
    return closestSquadID
end

-- Returns the squadID whose members are exactly the given units (same set and
-- count), or nil if no existing squad matches. Used to leave an identical squad
-- untouched on re-selection instead of disbanding and recreating it, which would
-- otherwise reset its hull pulse phase and hover blend every time it's selected.
---@param unitIDs integer[] eligible unit IDs, in any order
---@return string|nil squadID the matching squad, or nil if none matches exactly
local function findSquadWithExactUnits(unitIDs)
    local count = #unitIDs
    if count == 0 then
        return nil
    end
    local squadID = squadIDByUnitID[unitIDs[1]]
    if not squadID then
        return nil
    end
    local existing = unitIDsBySquadID[squadID]
    if not existing or #existing ~= count then
        return nil
    end
    for i = 2, count do
        if squadIDByUnitID[unitIDs[i]] ~= squadID then
            return nil
        end
    end
    return squadID
end

function widget:SelectionChanged(selectedUnits)
    if not selectedUnits then return end

    -- Refresh the current selection lookup used to hide already-selected squads.
    selectedUnitSet = {}
    for i = 1, #selectedUnits do
        selectedUnitSet[selectedUnits[i]] = true
    end

    local selectionCount = #selectedUnits
    --Spring.Echo("Currently selected units: " .. selectionCount)

    if selectionCount <= 1 then
        return
    end

    -- Only ground-moving units may form a squad; exclude everything else.
    local squadUnits = {}
    for i = 1, selectionCount do
        local unitID = selectedUnits[i]
        if unitCanBeInSquad(unitID) then
            squadUnits[#squadUnits + 1] = unitID
        end
    end

    if #squadUnits <= 1 then
        return
    end

    --Spring.Echo("Creating squad for selected units...", squadUnits)

    -- If these exact units already form a squad (e.g. the player just clicked an
    -- existing squad), keep it so its animation/hover state carries over.
    if findSquadWithExactUnits(squadUnits) then
        return
    end

    -- Create a squad for the eligible selected units
    createSquad(squadUnits)
end

function widget:UnitDestroyed(unitID, unitDefID, teamID)
    disposeUnit(unitID)
end

function widget:UnitTaken(unitID, unitDefID, teamID)
    disposeUnit(unitID)
end

function widget:MousePress(x, y, button)
    if button ~= 1 then return false end -- Only left mouse button

    pendingSquadID = nil
    pendingIsDrag = false

    -- A second press landing quickly near the previous click is a double-click;
    -- cancel any deferred squad selection and skip squad handling entirely so the
    -- engine's double-click (select all units of type) is left untouched.
    if pendingCommitSquadID and pendingCommitTime then
        local dx = x - pendingCommitX
        local dy = y - pendingCommitY
        if dx * dx + dy * dy <= DOUBLE_CLICK_RADIUS * DOUBLE_CLICK_RADIUS
            and spDiffTimers(spGetTimer(), pendingCommitTime) <= DOUBLE_CLICK_TIME then
            pendingCommitSquadID = nil
            pendingCommitTime = nil
            return false
        end
    end

    local activeCommand = Spring.GetActiveCommand()
    if activeCommand ~= 0 then
        -- If there is an active command, do not process squad selection
        return false
    end

    -- Get the units near the mouse click position. Trace with onlyCoords=false so
    -- the description reflects the real target (unit/feature/ground); a click that
    -- lands on a unit must not select a squad.
    local traceType, coords = Spring.TraceScreenRay(x, y, false)

    if traceType ~= "ground" then
        return false
    end

    local units = Spring.GetUnitsInCylinder(coords[1], coords[3], SELECT_RADIUS) -- Adjust the radius as needed
    if #units > 0 then
        -- Pick the squad of the unit closest to the click position so that
        -- overlapping squads resolve to the one the user actually aimed at.
        local closestSquadID = nil
        local closestDistSq = math.huge
        for _, unitID in ipairs(units) do
            local squadID = squadIDByUnitID[unitID]
            if squadID then
                local ux, _, uz = spGetUnitPosition(unitID)
                if ux then
                    local dx = ux - coords[1]
                    local dz = uz - coords[3]
                    local distSq = dx * dx + dz * dz
                    if distSq < closestDistSq then
                        closestDistSq = distSq
                        closestSquadID = squadID
                    end
                end
            end
        end
        if closestSquadID then
            -- Defer the squad selection until release so we can tell a
            -- genuine click apart from the start of a drag-selection.
            pendingSquadID = closestSquadID
            -- Capture now whether the squad is already selected, before the
            -- engine's native click changes the selection.
            pendingSquadWasSelected = isSquadSelected(closestSquadID)
            -- Shift held at press time joins this squad onto the current selection.
            local _, _, _, shift = spGetModKeyState()
            pendingSquadShift = shift == true
            pendingPressX = x
            pendingPressY = y
        end
    end

    -- Always return false so the engine's native drag-selection keeps working;
    -- the squad selection (if any) is committed in widget:Update on release.
    return false
end

function widget:Update()
    -- Commit a deferred squad selection once the double-click window has passed
    -- without a second click arriving to cancel it.
    if pendingCommitSquadID and pendingCommitTime then
        if spDiffTimers(spGetTimer(), pendingCommitTime) > DOUBLE_CLICK_TIME then
            local commitSquadID = pendingCommitSquadID
            local commitWasSelected = pendingCommitWasSelected
            local commitShift = pendingCommitShift
            pendingCommitSquadID = nil
            pendingCommitTime = nil
            if unitIDsBySquadID[commitSquadID] then
                selectSquad(commitSquadID, commitWasSelected, commitShift)
            end
        end
    end

    if not pendingSquadID then
        return
    end

    local mx, my, lmb = spGetMouseState()

    if lmb then
        -- Still holding the button: once we move far enough, treat it as a drag
        -- and abandon the squad selection so the box-select can run untouched.
        if not pendingIsDrag then
            local dx = mx - pendingPressX
            local dy = my - pendingPressY
            if dx * dx + dy * dy > DRAG_THRESHOLD * DRAG_THRESHOLD then
                pendingIsDrag = true
            end
        end
        return
    end

    -- Button released: defer the squad selection (instead of committing now) so a
    -- quick second click can cancel it as a double-click. Only do so if it stayed
    -- a click (no drag).
    local squadID = pendingSquadID
    local wasDrag = pendingIsDrag
    local wasSelected = pendingSquadWasSelected
    local wasShift = pendingSquadShift
    pendingSquadID = nil
    pendingIsDrag = false

    if not wasDrag and unitIDsBySquadID[squadID] then
        pendingCommitSquadID = squadID
        pendingCommitWasSelected = wasSelected
        pendingCommitShift = wasShift
        pendingCommitTime = spGetTimer()
        pendingCommitX = mx
        pendingCommitY = my
    end
end


-------------------------------------------------------------------------------
-- GL4 hull rendering (ported from squad-selection.lua)
--
-- One shared VBO (2D world x,z + ground-sampled y) is re-uploaded per squad
-- per frame, then drawn as TRIANGLE_FAN (fill) and LINE_LOOP (border).
-- The 2D hull geometry is convex, so a fan starting from vertex 0 covers it.
-------------------------------------------------------------------------------

local HULL_MAX_VERTICES = 512
local hullShader = nil
local hullColorLoc = nil
local hullCentroidLoc = nil
local hullPulseLoc = nil
local hullVbo = nil
local hullVao = nil
local hullReady = false
local hullInitFailed = false -- so we don't spam retries after a failure
local hullTimeOrigin = nil -- wall-clock origin for pulse animation

local lastDrawTime = nil -- previous frame timer, for delta-time hover easing

-- Center->edge alpha gradient: alpha at the centroid as a fraction of the edge.
local HULL_GRADIENT_CENTER = 0.2

local hullVsSrc = [[
#version 330 compatibility

layout(location = 0) in vec3 position;

out vec3 worldPos;

void main() {
	worldPos = position;
	gl_Position = gl_ModelViewProjectionMatrix * vec4(position, 1.0);
}
]]

local hullFsSrc = [[
#version 330 compatibility

uniform vec4 color;
// centroidRadius.xy = squad centroid in world XZ
// centroidRadius.z  = max distance from centroid to a perimeter vertex (gradient norm)
uniform vec3 centroidRadius;
// breathing alpha multiplier (per-squad phase, computed CPU-side)
uniform float pulse;
// alpha at the centroid as a fraction of the edge alpha
uniform float gradientCenter;

in vec3 worldPos;

out vec4 fragColor;

void main() {
	float a = color.a;

	// soft center->edge alpha gradient
	vec2 toCenter = worldPos.xz - centroidRadius.xy;
	float dist = length(toCenter) / max(centroidRadius.z, 1.0);
	a *= mix(gradientCenter, 1.0, smoothstep(0.0, 1.0, dist));

	a *= pulse;

	fragColor = vec4(color.rgb, a);
}
]]

local function initGlHull()
	if hullReady or hullInitFailed then
		return hullReady
	end
	if not glCreateShader or not glGetVBO or not glGetVAO then
		--Spring.Echo("[Squads] GL4 unavailable - convex hull drawing disabled")
		hullInitFailed = true
		return false
	end

	hullShader = glCreateShader({
		vertex = hullVsSrc,
		fragment = hullFsSrc,
	})
	if not hullShader then
		local shaderLog = gl.GetShaderLog and gl.GetShaderLog() or "(no log)"
		--Spring.Echo("[Squads] Failed to compile hull shader: " .. tostring(shaderLog))
		hullInitFailed = true
		return false
	end
	hullColorLoc = glGetUniformLocation(hullShader, "color")
	hullCentroidLoc = glGetUniformLocation(hullShader, "centroidRadius")
	hullPulseLoc = glGetUniformLocation(hullShader, "pulse")
	local gradientLoc = glGetUniformLocation(hullShader, "gradientCenter")
	if gradientLoc then
		glUseShader(hullShader)
		glUniform(gradientLoc, HULL_GRADIENT_CENTER)
		glUseShader(0)
	end

	hullVbo = glGetVBO(GL.ARRAY_BUFFER, false)
	if not hullVbo then
		glDeleteShader(hullShader)
		hullShader = nil
		--Spring.Echo("[Squads] Failed to create hull VBO")
		hullInitFailed = true
		return false
	end
	hullVbo:Define(HULL_MAX_VERTICES, {
		{
			id = 0,
			name = 'position',
			size = 3,
		}})

	hullVao = glGetVAO()
	if not hullVao then
		hullVbo:Delete()
		hullVbo = nil
		glDeleteShader(hullShader)
		hullShader = nil
		--Spring.Echo("[Squads] Failed to create hull VAO")
		hullInitFailed = true
		return false
	end
	hullVao:AttachVertexBuffer(hullVbo)

	hullReady = true
	return true
end


local function cleanupGlHull()
	if hullVao then
		hullVao:Delete()
	end
	if hullVbo then
		hullVbo:Delete()
	end
	if hullShader then
		glDeleteShader(hullShader)
	end
	hullVao = nil
	hullVbo = nil
	hullShader = nil
	hullColorLoc = nil
	hullCentroidLoc = nil
	hullPulseLoc = nil
	hullReady = false
	hullInitFailed = false
end


-------------------------------------------------------------------------------
-- Convex hull math (ported from squad-selection.lua)
--
-- Persistent scratch buffers. Tables inside are reused across frames.
-- scratchHull / scratchUpper hold refs *into* scratchWorld, not new tables.
-------------------------------------------------------------------------------

local scratchWorld = {} -- {x=world_x, y=world_z} per unit
local scratchHull = {} -- refs into scratchWorld
local scratchUpper = {} -- internal to convexHull
local scratchPadded = {} -- {x, y} per padded-hull vertex
local scratchFlat = {} -- flat {x, y, z, x, y, z, ...} for VBO upload

local function comparePoints(a, b)
	return a.x < b.x or (a.x == b.x and a.y < b.y)
end


local function cross(o, a, b)
	return (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
end


local function truncate(buf, newLen)
	for i = #buf, newLen + 1, -1 do
		buf[i] = nil
	end
end


-- Writes refs-into-world into out. Sorts `world` in place. Expects #world == n.
local function convexHull(world, n, out, upper)
	table.sort(world, comparePoints)

	local h = 0
	for i = 1, n do
		local p = world[i]
		while h >= 2 and cross(out[h - 1], out[h], p) <= 0 do
			out[h] = nil
			h = h - 1
		end
		h = h + 1
		out[h] = p
	end

	local u = 0
	for i = n, 1, -1 do
		local p = world[i]
		while u >= 2 and cross(upper[u - 1], upper[u], p) <= 0 do
			upper[u] = nil
			u = u - 1
		end
		u = u + 1
		upper[u] = p
	end

	for i = 2, u - 1 do
		h = h + 1
		out[h] = upper[i]
	end

	truncate(upper, 0)
	truncate(out, h)
	return h
end


-- circle for squads with only one unit. Writes into out, reuses its tables.
local function paddedCircle(cx, cy, radius, arcSegmentsAngle, out)
	local segments = math.max(math.ceil(2 * math.pi / arcSegmentsAngle), 3)
	for i = 0, segments - 1 do
		local angle = 2 * math.pi * i / segments
		local p = out[i + 1]
		if not p then
			p = {}
			out[i + 1] = p
		end
		p.x = cx + radius * math.cos(angle)
		p.y = cy + radius * math.sin(angle)
	end
	truncate(out, segments)
	return segments
end


-- rounded padded convex hull for 2+ units. Writes into out, reuses its tables.
local function paddedMoreThanOneUnit(hull, nHull, radius, arcSegmentsAngle, out)
	local n = 0
	for i = 1, nHull do
		local prev = hull[i == 1 and nHull or i - 1]
		local curr = hull[i]
		local nxt = hull[i == nHull and 1 or i + 1]

		local dxPrev = curr.x - prev.x
		local dyPrev = curr.y - prev.y
		local dxNext = nxt.x - curr.x
		local dyNext = nxt.y - curr.y

		-- right normals (outward for CCW): (dy, -dx)
		local anglePrev = math.atan2(-dxPrev, dyPrev)
		local angleNext = math.atan2(-dxNext, dyNext)
		local angleDiff = angleNext - anglePrev
		while angleDiff < 0 do
			angleDiff = angleDiff + 2 * math.pi
		end
		local arcSegments = math.max(math.ceil(angleDiff / arcSegmentsAngle), 1)
		for j = 0, arcSegments do
			local t = j / arcSegments
			local theta = anglePrev + t * angleDiff
			n = n + 1
			local p = out[n]
			if not p then
				p = {}
				out[n] = p
			end
			p.x = curr.x + radius * math.cos(theta)
			p.y = curr.y + radius * math.sin(theta)
		end
	end
	truncate(out, n)
	return n
end


-- Fill scratchPadded from scratchWorld[1..nWorld]. Returns padded count.
local function getPaddedHull(nWorld, radius, arcSegmentsAngle)
	if nWorld == 1 then
		local p = scratchWorld[1]
		return paddedCircle(p.x, p.y, radius, arcSegmentsAngle, scratchPadded)
	elseif nWorld >= 2 then
		local nHull = convexHull(scratchWorld, nWorld, scratchHull, scratchUpper)
		return paddedMoreThanOneUnit(scratchHull, nHull, radius, arcSegmentsAngle, scratchPadded)
	else
		truncate(scratchPadded, 0)
		return 0
	end
end


function widget:DrawWorldPreUnit()
	if spIsGUIHidden() then
		return
	end
	if not next(unitIDsBySquadID) then
		return
	end
	if not hullReady and not initGlHull() then
		return
	end

	local fillOpacity = config.convexHullFillOpacity
	local borderOpacity = config.convexHullBorderOpacity
	local borderThickness = config.convexHullBorderThickness
	local padding = config.convexHullPadding
	local arcRes = config.convexHullArcResolution

	if not hullTimeOrigin then
		hullTimeOrigin = spGetTimer()
	end
	local now = spDiffTimers(spGetTimer(), hullTimeOrigin)

	-- delta-time for the hover ease-in/out (clamped so a long stall can't jump)
	local dt = 0
	if lastDrawTime then
		dt = spDiffTimers(spGetTimer(), lastDrawTime)
		if dt > 0.1 then dt = 0.1 end
	end
	lastDrawTime = spGetTimer()
	local easeStep = config.hoverEaseSpeed * dt

	glDepthTest(false)
	glUseShader(hullShader)
	glLineWidth(borderThickness)

	local cr, cg, cb = teamColor[1], teamColor[2], teamColor[3]
	local hoveredSquadID = getSquadUnderMouse()

	for squadID, units in pairs(unitIDsBySquadID) do
		local size = #units
		if size > 0 then
			-- fill scratchWorld in place (reuse {x,y} tables) and track the bbox
			-- in the same pass, so we can frustum-cull without a second iteration.
			local nWorld = 0
			local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
			for i = 1, size do
				local x, _, z = spGetUnitPosition(units[i])
				if x and z then
					nWorld = nWorld + 1
					local p = scratchWorld[nWorld]
					if not p then
						p = {}
						scratchWorld[nWorld] = p
					end
					p.x = x
					p.y = z
					if x < minX then minX = x end
					if x > maxX then maxX = x end
					if z < minZ then minZ = z end
					if z > maxZ then maxZ = z end
				end
			end
			truncate(scratchWorld, nWorld)

			if nWorld > 0 then
				-- Frustum cull: enclose the squad + padding in one sphere around
				-- the bbox centre. Vertical slop (256) covers terrain variation
				-- under the ground-projected hull.
				local bcx = (minX + maxX) * 0.5
				local bcz = (minZ + maxZ) * 0.5
				local hx = (maxX - minX) * 0.5
				local hz = (maxZ - minZ) * 0.5
				local bcy = spGetGroundHeight(bcx, bcz)
				local cullRadius = math.sqrt(hx * hx + hz * hz) + padding + 256
				local visible = (not spIsSphereInView) or spIsSphereInView(bcx, bcy, bcz, cullRadius)

				if visible then
					local n = getPaddedHull(nWorld, padding, arcRes)
					if n >= 3 and n <= HULL_MAX_VERTICES then
						local seed = squadSeedBySquadID[squadID] or 0

						-- Centroid (average of padded vertices) and max radius are
						-- uploaded as a uniform to drive the fragment-shader
						-- center->edge alpha gradient. The hull stays convex so
						-- TRIANGLE_FAN can still pivot on vertex 0.
						local pcx, pcy = 0, 0
						local fi = 0
						for i = 1, n do
							local p = scratchPadded[i]
							pcx = pcx + p.x
							pcy = pcy + p.y
							scratchFlat[fi + 1] = p.x
							scratchFlat[fi + 2] = spGetGroundHeight(p.x, p.y)
							scratchFlat[fi + 3] = p.y
							fi = fi + 3
						end
						pcx = pcx / n
						pcy = pcy / n

						local maxR2 = 0
						for i = 1, n do
							local p = scratchPadded[i]
							local rdx = p.x - pcx
							local rdy = p.y - pcy
							local r2 = rdx * rdx + rdy * rdy
							if r2 > maxR2 then
								maxR2 = r2
							end
						end
						local hullRadiusNorm = math.sqrt(maxR2)

						hullVbo:Upload(scratchFlat, nil, nil, 1, fi)

						local pulseVal = 1 + config.hullPulseAmplitude * math.sin(now * config.hullPulseRate + seed * 6.2831853)
						glUniform(hullCentroidLoc, pcx, pcy, hullRadiusNorm)
						glUniform(hullPulseLoc, pulseVal)

						local hovered = squadID == hoveredSquadID or isSquadSelected(squadID)

						-- Advance the eased hover blend toward 1 (hovered) or 0.
						local blend = hoverBlendBySquadID[squadID] or 0
						local target = hovered and 1 or 0
						if blend ~= target then
							if blend < target then
								blend = math.min(blend + easeStep, target)
							else
								blend = math.max(blend - easeStep, target)
							end
							hoverBlendBySquadID[squadID] = blend
						end
						-- smoothstep for ease in/out
						local e = blend * blend * (3 - 2 * blend)

						-- Keep the regular team color; only ramp opacity/thickness.
						local fillA = fillOpacity + config.hoverFillOpacityBonus * e
						local borderA = borderOpacity + config.hoverBorderOpacityBonus * e
						if fillA > 1 then fillA = 1 end
						if borderA > 1 then borderA = 1 end
						glLineWidth(borderThickness + (config.hoverBorderThickness - borderThickness) * e)

						glUniform(hullColorLoc, cr, cg, cb, fillA)
						hullVao:DrawArrays(GL.TRIANGLE_FAN, n)
						glUniform(hullColorLoc, cr, cg, cb, borderA)
						hullVao:DrawArrays(GL.LINE_LOOP, n)
					end
				end
			end
		end
	end

	glUseShader(0)
	glLineWidth(1)
	glDepthTest(true)
	glColor(1, 1, 1, 1)
end


function widget:Initialize()
	local tr, tg, tb = spGetTeamColor(spGetMyTeamID())
	teamColor[1], teamColor[2], teamColor[3] = tr or 1, tg or 1, tb or 1
end


function widget:Shutdown()
	cleanupGlHull()
end

