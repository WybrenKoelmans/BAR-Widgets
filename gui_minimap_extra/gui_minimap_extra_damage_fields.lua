local widget = widget ---@type Widget

function widget:GetInfo()
  return {
    name = "Minimap Extra - Damage Fields",
    desc = "Enhances the minimap with damage visualization that fades over time",
    author = "uBdead, used a lot of code by ivand, esainane, Lexon and efrec",
    date = "2025-09-05",
    license = "GNU GPL, v2 or later",
    layer = -998,
    enabled = true,
    depends = {'gl4'}
  }
end

-- Local data & helpers (placed here so later functions can reference them)
local DAMAGE_MEMORY_SECONDS = 30        -- seconds to retain damage points
local SIM_FPS = 30                      -- assumed sim frames per second
local DAMAGE_MEMORY_FRAMES = DAMAGE_MEMORY_SECONDS * SIM_FPS

local damageEvents = {}  -- { {x,z,damage,frame}, ... }
local clusters = {}      -- { { points = {events}, hull = {x,z}, newestFrame = n }, ... }
local eventsDirty = false
local MAX_POINTS = 200  -- hard cap just in case of extreme spam

-- Drawing config (can be later exposed to options)
local fillColor = {1, 0, 0, 0.35}  -- RGBA for fill (much more opaque)
local lineColor = {1, 0.3, 0.1, 0.1}
local lineWidth = 1
local alphaMaxFill = 0.7  -- allow up to full opacity for pulse
local alphaMaxLine = 0.9

-- Pulse configuration (handled in Update to decouple from draw)
local pulsePeriodSeconds = 2.5          -- duration of one full in+out cycle
local pulseMin = 0.50                   -- lower multiplier bound
local pulseMax = 2                   -- upper multiplier bound
local pulseTime = 0                     -- accumulated time
local pulseFactor = 1                   -- current factor applied to alpha

-- Cross product of OA x OB (for convex hull orientation)
local function cross(o, a, b)
  return (a.x - o.x) * (b.z - o.z) - (a.z - o.z) * (b.x - o.x)
end

-- Euclidean distance squared
local function dist2(a, b)
  local dx, dz = a.x - b.x, a.z - b.z
  return dx*dx + dz*dz
end

-- Monotone chain convex hull (returns list of {x,z})
local function convexHull(points)
  if #points < 3 then return points end
  table.sort(points, function(a, b)
    if a.x == b.x then return a.z < b.z end
    return a.x < b.x
  end)
  local lower, upper = {}, {}
  for i = 1, #points do
    while #lower >= 2 and cross(lower[#lower-1], lower[#lower], points[i]) <= 0 do
      lower[#lower] = nil
    end
    lower[#lower+1] = points[i]
  end
  for i = #points, 1, -1 do
    while #upper >= 2 and cross(upper[#upper-1], upper[#upper], points[i]) <= 0 do
      upper[#upper] = nil
    end
    upper[#upper+1] = points[i]
  end
  upper[#upper] = nil
  lower[#lower] = nil
  local hull = {}
  for i=1,#lower do hull[#hull+1] = lower[i] end
  for i=1,#upper do hull[#hull+1] = upper[i] end
  return hull
end

-- Simple distance-based clustering (single-linkage, not OPTICS/DBSCAN, but fast for minimap)
local CLUSTER_DIST = 600 -- map units (tune as needed)
local CLUSTER_DIST2 = CLUSTER_DIST * CLUSTER_DIST
local function clusterDamageEvents(events)
  local clusters = {}
  local assigned = {}
  for i, e in ipairs(events) do
    if not assigned[i] then
      local cluster = { points = {e}, newestFrame = e.frame }
      assigned[i] = true
      -- Add all events within CLUSTER_DIST2 (single-linkage)
      for j = i+1, #events do
        if not assigned[j] then
          for _, ce in ipairs(cluster.points) do
            if dist2(ce, events[j]) <= CLUSTER_DIST2 then
              cluster.points[#cluster.points+1] = events[j]
              assigned[j] = true
              if events[j].frame > cluster.newestFrame then cluster.newestFrame = events[j].frame end
              break
            end
          end
        end
      end
      clusters[#clusters+1] = cluster
    end
  end
  return clusters
end


local function RebuildClusters()
  eventsDirty = false
  clusters = {}
  if #damageEvents < 1 then return end
  -- Cluster events
  local clustered = clusterDamageEvents(damageEvents)
  -- For each cluster, compute hull and newestFrame
  for _, c in ipairs(clustered) do
    local pts = {}
    local newest = 0
    for _, e in ipairs(c.points) do
      pts[#pts+1] = {x = e.x, z = e.z}
      if e.frame > newest then newest = e.frame end
    end
    local hull = convexHull(pts)
    clusters[#clusters+1] = { points = c.points, hull = hull, newestFrame = newest }
  end
end


function widget:UnitDamaged(unitID, unitDefID, unitTeam, damage, paralyzer)
  -- Store damage event (we only need x,z for minimap polygon)
  local x, y, z = Spring.GetUnitPosition(unitID)
  if not x then return end
  local gf = Spring.GetGameFrame()
  if #damageEvents >= MAX_POINTS then
    -- Drop oldest 10% to make room
    local drop = math.floor(#damageEvents * 0.1)
    for i=1, #damageEvents - drop do
      damageEvents[i] = damageEvents[i + drop]
    end
    for i=#damageEvents - drop + 1, #damageEvents do damageEvents[i] = nil end
  end
  damageEvents[#damageEvents+1] = {x = x, z = z, damage = damage, frame = gf}
  eventsDirty = true
end


function widget:DrawInMiniMap(sizeX, sizeY)
  if eventsDirty then
    RebuildClusters()
  end
  if not clusters or #clusters == 0 then return end

  gl.PushMatrix()
  -- Minimap coords need scaling (0..mapSizeX, 0..mapSizeZ) -> minimap space with y inverted
  gl.Translate(0, sizeY, 0)
  gl.Scale(sizeX / Game.mapSizeX, -sizeY / Game.mapSizeZ, 1)

  gl.DepthTest(false)
  gl.Blending(GL.SRC_ALPHA, GL.ONE_MINUS_SRC_ALPHA)

  local gf = Spring.GetGameFrame()
  for _, c in ipairs(clusters) do
    local hull = c.hull
    if hull and #hull >= 3 then
      local age = gf - c.newestFrame
      local alphaMul = 1 - math.min(1, age / DAMAGE_MEMORY_FRAMES)
      if alphaMul > 0 then
        -- Apply pulse factor (updated in Update)
        local finalAlpha = alphaMul * pulseFactor
        -- Fill
        local cx, cz = 0, 0
        for i=1,#hull do cx = cx + hull[i].x; cz = cz + hull[i].z end
        cx = cx / #hull; cz = cz / #hull
        gl.Color(fillColor[1], fillColor[2], fillColor[3], math.min(alphaMaxFill, fillColor[4] * finalAlpha))
        gl.BeginEnd(GL.TRIANGLE_FAN, function()
          gl.Vertex(cx, cz)
          for i=1,#hull do gl.Vertex(hull[i].x, hull[i].z) end
          gl.Vertex(hull[1].x, hull[1].z)
        end)
        -- Outline
        gl.Color(lineColor[1], lineColor[2], lineColor[3], math.min(alphaMaxLine, lineColor[4] * finalAlpha))
        gl.LineWidth(lineWidth)
        gl.BeginEnd(GL.LINE_LOOP, function()
          for i=1,#hull do gl.Vertex(hull[i].x, hull[i].z) end
        end)
      end
    end
  end
  gl.Color(1,1,1,1)
  gl.PopMatrix()
end

function widget:Update(dt)
  -- dt can be nil in some engine versions; fall back to sim frame step (1/SIM_FPS)
  if not dt or dt <= 0 then dt = 1 / SIM_FPS end
  pulseTime = pulseTime + dt
  if pulsePeriodSeconds <= 0 then
    pulseFactor = 1
    return
  end
  local t = (pulseTime % pulsePeriodSeconds) / pulsePeriodSeconds  -- 0..1
  -- cosine ease in-out (slow near peaks)
  local eased = 0.5 - 0.5 * math.cos(2 * math.pi * t)             -- 0..1
  pulseFactor = pulseMin + (pulseMax - pulseMin) * eased
end


function widget:GameFrame(n)
  -- Periodically purge old events & mark dirty
  if n % 30 == 5 then -- every second (assuming 30fps sim)
    local cutoff = n - DAMAGE_MEMORY_FRAMES
    local newEvents = {}
    local changed = false
    for i=1,#damageEvents do
      local e = damageEvents[i]
      if e.frame >= cutoff then
        newEvents[#newEvents+1] = e
      else
        changed = true
      end
    end
    if changed then
      damageEvents = newEvents
      eventsDirty = true
    end
  end
end
