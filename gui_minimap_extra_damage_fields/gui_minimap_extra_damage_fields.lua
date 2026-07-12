local widget = widget ---@type Widget

function widget:GetInfo()
  return {
    name    = "Minimap Extra - Damage Fields",
    desc    = "Enhances the minimap with damage visualization that fades over time",
    author  = "uBdead, used a lot of code by ivand, esainane, Lexon and efrec",
    date    = "2025-09-05",
    license = "GNU GPL, v2 or later",
    layer   = -998,
    enabled = true,
    depends = { 'gl4' },
  }
end

--------------------------------------------------------------------------------
-- Localized engine API (avoids global table lookups on every call)
--------------------------------------------------------------------------------
local spGetUnitPosition = Spring.GetUnitPosition
local spGetGameFrame    = Spring.GetGameFrame

local glPushMatrix   = gl.PushMatrix
local glPopMatrix    = gl.PopMatrix
local glLoadIdentity = gl.LoadIdentity
local glTranslate    = gl.Translate
local glScale        = gl.Scale
local glRotate       = gl.Rotate
local glDepthTest    = gl.DepthTest
local glBlending     = gl.Blending
local glColor        = gl.Color
local glBeginEnd     = gl.BeginEnd
local glVertex       = gl.Vertex
local glLineWidth    = gl.LineWidth

local GL_SRC_ALPHA           = GL.SRC_ALPHA
local GL_ONE_MINUS_SRC_ALPHA = GL.ONE_MINUS_SRC_ALPHA
local GL_TRIANGLE_FAN        = GL.TRIANGLE_FAN
local GL_LINE_LOOP           = GL.LINE_LOOP

local mathMin   = math.min
local mathFloor = math.floor
local mathCos   = math.cos
local mathPi    = math.pi

local mapSizeX = Game.mapSizeX
local mapSizeZ = Game.mapSizeZ

--------------------------------------------------------------------------------
-- Minimap rotation support (handles Alt+O and other orientation changes)
--------------------------------------------------------------------------------
local _minimap_utils              = VFS.Include("luaui/Include/minimap_utils.lua")
local getCurrentMiniMapRotation   = _minimap_utils.getCurrentMiniMapRotationOption
local ROTATION                    = _minimap_utils.ROTATION
_minimap_utils = nil  -- release reference; we kept what we need

--------------------------------------------------------------------------------
-- Config
--------------------------------------------------------------------------------
local DAMAGE_MEMORY_SECONDS = 30
local SIM_FPS               = 30
local DAMAGE_MEMORY_FRAMES  = DAMAGE_MEMORY_SECONDS * SIM_FPS
local MAX_POINTS            = 200   -- hard cap on tracked damage events

local CLUSTER_DIST  = 600           -- map-unit radius for single-linkage clustering
local CLUSTER_DIST2 = CLUSTER_DIST * CLUSTER_DIST

-- Visual
local fillColor    = { 1, 0, 0, 0.35 }
local lineColor    = { 1, 0.3, 0.1, 0.1 }
local lineWidth    = 1
local alphaMaxFill = 0.7
local alphaMaxLine = 0.9

-- Pulse (computed each Update, consumed in DrawInMiniMap)
local pulsePeriodSeconds = 2.5
local pulseMin           = 0.50
local pulseMax           = 2.0
local pulseTime          = 0
local pulseFactor        = 1.0

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------
local damageEvents = {}   -- array of { x, z, damage, frame }
local clusters     = {}   -- array of { hull, cx, cz, newestFrame }
local eventsDirty  = false

--------------------------------------------------------------------------------
-- Geometry helpers
--------------------------------------------------------------------------------

-- Cross product of OA x OB used for convex-hull winding tests
local function cross(o, a, b)
  return (a.x - o.x) * (b.z - o.z) - (a.z - o.z) * (b.x - o.x)
end

-- Squared Euclidean distance between two {x,z} points
local function dist2(a, b)
  local dx, dz = a.x - b.x, a.z - b.z
  return dx * dx + dz * dz
end

-- Monotone-chain convex hull; returns a {x,z} vertex list
local function convexHull(points)
  local n = #points
  if n < 3 then return points end
  table.sort(points, function(a, b)
    return a.x == b.x and a.z < b.z or a.x < b.x
  end)
  local lower, upper = {}, {}
  for i = 1, n do
    while #lower >= 2 and cross(lower[#lower-1], lower[#lower], points[i]) <= 0 do
      lower[#lower] = nil
    end
    lower[#lower+1] = points[i]
  end
  for i = n, 1, -1 do
    while #upper >= 2 and cross(upper[#upper-1], upper[#upper], points[i]) <= 0 do
      upper[#upper] = nil
    end
    upper[#upper+1] = points[i]
  end
  -- Remove shared endpoints before concatenating lower + upper chains
  lower[#lower] = nil
  upper[#upper] = nil
  local hull = {}
  for i = 1, #lower do hull[#hull+1] = lower[i] end
  for i = 1, #upper do hull[#hull+1] = upper[i] end
  return hull
end

-- Single-linkage distance clustering (O(n²), fast enough for MAX_POINTS = 200)
local function clusterDamageEvents(events)
  local result   = {}
  local assigned = {}
  for i = 1, #events do
    if not assigned[i] then
      local cluster = { points = { events[i] }, newestFrame = events[i].frame }
      assigned[i] = true
      for j = i + 1, #events do
        if not assigned[j] then
          for _, ce in ipairs(cluster.points) do
            if dist2(ce, events[j]) <= CLUSTER_DIST2 then
              local e = events[j]
              cluster.points[#cluster.points+1] = e
              assigned[j] = true
              if e.frame > cluster.newestFrame then
                cluster.newestFrame = e.frame
              end
              break
            end
          end
        end
      end
      result[#result+1] = cluster
    end
  end
  return result
end

--------------------------------------------------------------------------------
-- Cluster rebuild (called lazily when eventsDirty is true)
--------------------------------------------------------------------------------
local function RebuildClusters()
  eventsDirty = false
  -- Clear in-place to avoid re-allocating the table every rebuild
  for i = #clusters, 1, -1 do clusters[i] = nil end
  if #damageEvents == 0 then return end

  local raw = clusterDamageEvents(damageEvents)
  for _, c in ipairs(raw) do
    local pts    = {}
    local newest = 0
    for _, e in ipairs(c.points) do
      pts[#pts+1] = { x = e.x, z = e.z }
      if e.frame > newest then newest = e.frame end
    end

    local hull = convexHull(pts)

    -- Pre-compute centroid once here so DrawInMiniMap never recomputes it
    local cx, cz = 0, 0
    local hullN = #hull
    for i = 1, hullN do
      cx = cx + hull[i].x
      cz = cz + hull[i].z
    end
    if hullN > 0 then
      cx = cx / hullN
      cz = cz / hullN
    end

    clusters[#clusters+1] = {
      hull        = hull,
      cx          = cx,
      cz          = cz,
      newestFrame = newest,
    }
  end
end

--------------------------------------------------------------------------------
-- gl.BeginEnd draw helpers (named functions avoid per-frame closure allocation)
--------------------------------------------------------------------------------
local function drawFanVertices(hull, hullN, cx, cz)
  glVertex(cx, cz)
  for i = 1, hullN do glVertex(hull[i].x, hull[i].z) end
  glVertex(hull[1].x, hull[1].z)  -- close the fan
end

local function drawLoopVertices(hull, hullN)
  for i = 1, hullN do glVertex(hull[i].x, hull[i].z) end
end

--------------------------------------------------------------------------------
-- Widget call-ins
--------------------------------------------------------------------------------
function widget:UnitDamaged(unitID, unitDefID, unitTeam, damage, paralyzer)
  local x, _, z = spGetUnitPosition(unitID)
  if not x then return end

  local gf = spGetGameFrame()
  if #damageEvents >= MAX_POINTS then
    -- Evict oldest 10 % to make room (O(n) shift; tolerable at MAX_POINTS = 200)
    local drop = mathFloor(#damageEvents * 0.1)
    local keep = #damageEvents - drop
    for i = 1, keep do
      damageEvents[i] = damageEvents[i + drop]
    end
    for i = keep + 1, #damageEvents do
      damageEvents[i] = nil
    end
  end

  damageEvents[#damageEvents+1] = { x = x, z = z, damage = damage, frame = gf }
  eventsDirty = true
end


function widget:DrawInMiniMap(sizeX, sizeY)
  -- Skip when the PIP minimap widget is handling its own overlay pass
  if WG['minimap'] and WG['minimap'].isDrawingInPip then return end

  if eventsDirty then RebuildClusters() end
  if #clusters == 0 then return end

  local gf = spGetGameFrame()

  glPushMatrix()
  glLoadIdentity()

  -- Map world (x, z) coords onto the 0..1 normalised minimap space,
  -- accounting for the current minimap rotation (Alt+O cycles through 0/90/180/270°).
  -- Transforms mirror the BAR-standard pattern from gui_buildbar / cmd_customformations2.
  local rot = getCurrentMiniMapRotation() or ROTATION.DEG_0
  if rot == ROTATION.DEG_0 then
    glTranslate(0, 1, 0)
    glScale(1 / mapSizeX, -1 / mapSizeZ, 1)
  elseif rot == ROTATION.DEG_90 then
    glScale(-1 / mapSizeZ, 1 / mapSizeX, 1)
    glRotate(90, 0, 0, 1)
  elseif rot == ROTATION.DEG_180 then
    glTranslate(1, 0, 0)
    glScale(1 / mapSizeX, 1 / mapSizeZ, 1)
    glRotate(180, 0, 1, 0)
  elseif rot == ROTATION.DEG_270 then
    glTranslate(1, 1, 0)
    glScale(-1 / mapSizeZ, 1 / mapSizeX, 1)
    glRotate(-90, 0, 0, 1)
  end

  glDepthTest(false)
  glBlending(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)

  for _, c in ipairs(clusters) do
    local hull  = c.hull
    local hullN = #hull
    if hullN >= 3 then
      local age      = gf - c.newestFrame
      local alphaMul = 1 - mathMin(1, age / DAMAGE_MEMORY_FRAMES)
      if alphaMul > 0.001 then  -- skip essentially invisible clusters
        local finalAlpha = alphaMul * pulseFactor

        -- Filled hull (fan from pre-computed centroid)
        glColor(fillColor[1], fillColor[2], fillColor[3],
                mathMin(alphaMaxFill, fillColor[4] * finalAlpha))
        glBeginEnd(GL_TRIANGLE_FAN, drawFanVertices, hull, hullN, c.cx, c.cz)

        -- Outline
        glColor(lineColor[1], lineColor[2], lineColor[3],
                mathMin(alphaMaxLine, lineColor[4] * finalAlpha))
        glLineWidth(lineWidth)
        glBeginEnd(GL_LINE_LOOP, drawLoopVertices, hull, hullN)
      end
    end
  end

  glColor(1, 1, 1, 1)
  glPopMatrix()
end


function widget:Update(dt)
  if not dt or dt <= 0 then dt = 1 / SIM_FPS end
  pulseTime = pulseTime + dt
  if pulsePeriodSeconds <= 0 then
    pulseFactor = 1
    return
  end
  -- Cosine ease in-out: slow at peaks, fast through mid-cycle
  local t     = (pulseTime % pulsePeriodSeconds) / pulsePeriodSeconds  -- 0..1
  local eased = 0.5 - 0.5 * mathCos(2 * mathPi * t)                   -- 0..1
  pulseFactor = pulseMin + (pulseMax - pulseMin) * eased
end


function widget:GameFrame(n)
  -- Purge expired events once per second (~30 sim frames)
  if n % 30 ~= 5 then return end

  local cutoff  = n - DAMAGE_MEMORY_FRAMES
  local write   = 1
  local changed = false

  -- In-place compaction: no new table allocation each second
  for read = 1, #damageEvents do
    local e = damageEvents[read]
    if e.frame >= cutoff then
      damageEvents[write] = e
      write = write + 1
    else
      changed = true
    end
  end
  for i = write, #damageEvents do
    damageEvents[i] = nil
  end

  if changed then
    eventsDirty = true
  end
end
