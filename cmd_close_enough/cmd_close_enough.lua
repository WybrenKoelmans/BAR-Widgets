local widget = widget ---@type Widget

function widget:GetInfo()
  return {
    name    = "Close Enough",
    desc    = "Clicking right next to a unit (so missing it), will just select it anyway.",
    author  = "uBdead",
    date    = "2026-04-08",
    license = "GNU GPL, v2 or later",
    layer   = 0,
    enabled = true
  }
end

--------------------------------------------------------------------------------
-- Spring API locals
--------------------------------------------------------------------------------

local spTraceScreenRay     = Spring.TraceScreenRay
local spGetUnitsInCylinder = Spring.GetUnitsInCylinder
local spGetUnitPosition    = Spring.GetUnitPosition
local spGetUnitDefID       = Spring.GetUnitDefID
local spSelectUnitArray    = Spring.SelectUnitArray
local spGetSelectedUnits   = Spring.GetSelectedUnits
local spGetActiveCommand   = Spring.GetActiveCommand
local spGetModKeyState     = Spring.GetModKeyState
local spGetMyTeamID        = Spring.GetMyTeamID

--------------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------------

local config = {
  radius           = 50,  -- elmos around the click to search for units
  includeBuildings = false, -- also "close enough" select buildings
}

-- Set of UnitDefIDs that should never be selected (decorative objects, etc.)
local ignoreUnits = {}
for udid, udef in pairs(UnitDefs) do
  if udef.modCategories and udef.modCategories['object']
      or (udef.customParams and udef.customParams.objectify) then
    ignoreUnits[udid] = true
  end
end

--------------------------------------------------------------------------------
-- Options (WG['options'])
--------------------------------------------------------------------------------

local optionsRegistered = false

local function registerOptions()
  if not WG['options'] or not WG['options'].addOptions then
    return false
  end

  WG['options'].addOptions({
    { id = "close_enough_label", name = "Close Enough", type = "label" },
    { id = "close_enough_spacer" },
    { id = "close_enough_radius",
      name = "Selection Radius",
      type = "slider",
      min = 25, max = 300, step = 25,
      value = config.radius,
      description = "How close (in elmos) you need to click to a unit for it to count as a hit.",
      onchange = function(_, value)
        config.radius = value
      end,
    },
    { id = "close_enough_buildings",
      name = "Include Buildings",
      type = "bool",
      value = config.includeBuildings,
      description = "Also select buildings when clicking near them.",
      onchange = function(_, value)
        config.includeBuildings = value
      end,
    },
  })

  optionsRegistered = true
  return true
end

local function removeOptions()
  if WG['options'] and WG['options'].removeOptions then
    WG['options'].removeOptions({
      "close_enough_label",
      "close_enough_spacer",
      "close_enough_radius",
      "close_enough_buildings",
      "close_enough_own_only",
    })
  end
end

--------------------------------------------------------------------------------
-- Widget call-ins
--------------------------------------------------------------------------------

function widget:Initialize()
  registerOptions()
end

function widget:Update()
  if not optionsRegistered then
    registerOptions()
  end
end

function widget:Shutdown()
  removeOptions()
end

function widget:MousePress(x, y, button)
  -- Only left mouse button
  if button ~= 1 then return end

  -- Don't interfere when a command is active (build, attack, patrol, etc.)
  if spGetActiveCommand() ~= 0 then return end

  -- If the click directly hit a unit, let the engine handle it normally
  local hitType = spTraceScreenRay(x, y)
  if hitType == "unit" then return end

  -- Get the world position of the click
  local _, worldPos = spTraceScreenRay(x, y, true)
  if not worldPos then return end

  local wx, wz = worldPos[1], worldPos[3]

  -- Find units in the configured radius
  local teamFilter = spGetMyTeamID()
  local nearbyUnits = spGetUnitsInCylinder(wx, wz, config.radius, teamFilter)
  if not nearbyUnits or #nearbyUnits == 0 then return end

  -- Find the closest valid unit
  local closestUnit = nil
  local closestDistSq = math.huge

  for _, unitID in ipairs(nearbyUnits) do
    local unitDefID = spGetUnitDefID(unitID)
    if unitDefID and not ignoreUnits[unitDefID] then
      local udef = UnitDefs[unitDefID]
      if config.includeBuildings or not udef.isBuilding then
        local ux, _, uz = spGetUnitPosition(unitID)
        if ux then
          local dx = ux - wx
          local dz = uz - wz
          local distSq = dx * dx + dz * dz
          if distSq < closestDistSq then
            closestDistSq = distSq
            closestUnit = unitID
          end
        end
      end
    end
  end

  if not closestUnit then return end

  -- Shift held = add to existing selection
  local _, _, _, shift = spGetModKeyState()
  if shift then
    local currentSel = spGetSelectedUnits()
    currentSel[#currentSel + 1] = closestUnit
    spSelectUnitArray(currentSel)
  else
    spSelectUnitArray({ closestUnit })
  end

  return true -- consume the click
end

