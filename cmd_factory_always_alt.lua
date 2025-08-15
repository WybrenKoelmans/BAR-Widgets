local widget = widget ---@type Widget

function widget:GetInfo()
  return {
    name    = "Factory Always-Alt Queue",
    desc    = "Always queue certain units (e.g. constructors) with alt (priority) in factories.",
    author  = "uBdead",
    date    = "Jul 19 2025",
    license = "GNU GPL, v2 or later",
    layer   = 1,
    enabled = true
  }
end

local manualExclusions = {
  test = true,
  armepoch = true,
  armlance = true,
  armmship = true,
  armlship = true,
  armpt = true,
  cortitan = true,
  corpt = true,
  cormship = true,
  legfort = true,
  legamph = true,
}
local blackListedForRepeat = {}

function widget:Initialize()
  Spring.Echo("cmd_factory_always_alt.lua loaded and initialized.")
  if not UnitDefs then
    return
  end
  local count = 0
  -- Cache all unitdefs that are mobile constructors (isBuilder and not isFactory)
  for udid, ud in pairs(UnitDefs) do
    -- manualExclusions
    if not manualExclusions[ud.name] then
      -- No builders
      if ud.isBuilder and not ud.isFactory then
        blackListedForRepeat[udid] = ud
        count = count + 1
      end

      -- No transports
      if ud.isTransport then
        blackListedForRepeat[udid] = ud
        count = count + 1
      end

      -- No radar units, or jammers (TODO: this might be too broad)
      if (ud.radarDistance and ud.radarDistance > 0) or (ud.radarDistanceJam and ud.radarDistanceJam > 0) then
        blackListedForRepeat[udid] = ud
        count = count + 1
      end
    end
  end
end

-- Always queue constructors with alt (priority)
function widget:CommandNotify(cmdID, params, options)
  -- Build commands are negative cmdIDs
  if cmdID >= 0 then
    return false -- Not a build command
  end

  -- ignore if right click
  if options.right then
    return false -- Right click does not queue
  end

  local name = UnitDefs[-cmdID].name

  -- The cmdID is the unit being built
  local unitDefID = -cmdID
  if not blackListedForRepeat[unitDefID] then
    Spring.Echo("Unit " .. name .. " normal.")
    return false
  end

  -- Check if alt is held from the params
  local altHeld = options.alt or false
  if altHeld then
    return false -- Just handle the alt normally
  end

  -- Do the command with ALT automatically
  options.alt = true -- Set alt to true in options
  Spring.Echo("Unit " .. name .. " alt queued.")
  for _, factoryID in ipairs(Spring.GetSelectedUnits()) do
    Spring.GiveOrderToUnit(factoryID, cmdID, params, options)
  end
  return true
end
