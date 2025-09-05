local widget = widget ---@type Widget

function widget:GetInfo()
  return {
    name = "Minimap Extra - Idle Indicators",
    desc = "Enhances the minimap with idle unit indicators",
    author = "uBdead",
    date = "2025-09-05",
    license = "GNU GPL, v2 or later",
    layer = -998,
    enabled = true,
    depends = {'gl4'}
  }
end

-- Idle constructor tracking (gui_idle_builders logic)
local spGetAllUnits = Spring.GetAllUnits
local spGetUnitDefID = Spring.GetUnitDefID
local spGetUnitTeam = Spring.GetUnitTeam
local spGetUnitCommandCount = Spring.GetUnitCommandCount
local spGetUnitIsDead = Spring.GetUnitIsDead
local spGetUnitIsBeingBuilt = Spring.GetUnitIsBeingBuilt
local myTeamID = Spring.GetMyTeamID

local idleConstructors = {} -- { [unitID] = {x, z, seenFrame} }
local blipLifetime = 30 -- frames (1 second at 30fps)
local blipPeriod = 60   -- frames (2 seconds at 30fps)
local updatePeriod = 2.0 -- seconds
local lastUpdate = 0

function widget:Initialize()
  Spring.Echo("[idle-indicators] widget:Initialize called")
end

-- Identify constructor unitDefs using gui_idle_builders logic
local isIdleConstructor = {}
for unitDefID, unitDef in pairs(UnitDefs) do
  local cp = unitDef.customParams
  if not (cp and cp.virtualunit == "1") then
    if unitDef.buildSpeed > 0
      and not string.find(unitDef.name, 'spy')
      and not string.find(unitDef.name, 'infestor')
      and (unitDef.canAssist or unitDef.buildOptions[1] or unitDef.canResurrect)
      and not (cp and cp.isairbase)
    then
      isIdleConstructor[unitDefID] = true
    end
  end
end

function widget:Update(dt)
  lastUpdate = lastUpdate + dt
  if lastUpdate < updatePeriod then return end
  lastUpdate = 0

  local gf = Spring.GetGameFrame()
  local allUnits = spGetAllUnits()
  local newIdle = {}
  for i = 1, #allUnits do
    local unitID = allUnits[i]
    local unitDefID = spGetUnitDefID(unitID)
    local passes = true
    if not isIdleConstructor[unitDefID] then passes = false end
    if spGetUnitTeam(unitID) ~= myTeamID() then passes = false end
    if spGetUnitCommandCount(unitID) ~= 0 then passes = false end
    if spGetUnitIsDead(unitID) then passes = false end
    if spGetUnitIsBeingBuilt(unitID) then passes = false end
    if passes then
      local x, y, z = Spring.GetUnitPosition(unitID)
      if x and z then
        local prev = idleConstructors[unitID]
        newIdle[unitID] = {
          x = x,
          z = z,
          seenFrame = prev and prev.seenFrame or gf
        }
      end
    end
  end
  idleConstructors = newIdle
end

function widget:DrawInMiniMap(sizeX, sizeY)
  if not next(idleConstructors) then return end
  local gf = Spring.GetGameFrame()
  gl.PushMatrix()
  -- Transform world coordinates to minimap space
  gl.Translate(0, sizeY, 0)
  gl.Scale(sizeX / Game.mapSizeX, -sizeY / Game.mapSizeZ, 1)
  gl.PointSize(4)
  gl.BeginEnd(GL.POINTS, function()
    for unitID, data in pairs(idleConstructors) do
      local t = gf - data.seenFrame
      local cycleT = t % blipPeriod
      if cycleT <= blipLifetime then
        -- Instant in, ease-out (quadratic)
        local alpha = 1 - (cycleT / blipLifetime)^2
        gl.Color(1, 1, 0, alpha)
        gl.Vertex(data.x, data.z)
      end
    end
  end)
  gl.PointSize(1)
  gl.Color(1, 1, 1, 1)
  gl.PopMatrix()
end

