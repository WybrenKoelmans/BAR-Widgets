local widget = widget ---@type Widget

function widget:GetInfo()
  return {
    name    = "Factory Quota With Meta",
    desc    = "Holding Meta (spacebar) will manipulate the factory quota while clicking build orders in grid menu.",
    author  = "uBdead",
    date    = "2025.08.15",
    license = "GNU GPL, v2 or later",
    layer   = 0,
    enabled = true
  }
end

local heldMeta = false

local CONFIG = {
    sound_queue_add = "LuaUI/Sounds/buildbar_add.wav",
	  sound_queue_rem = "LuaUI/Sounds/buildbar_rem.wav",
}

function widget:Update()
  _, _, heldMeta = Spring.GetModKeyState()
end

local function IsFactory(unitDefID)
  local ud = UnitDefs[unitDefID]
  return ud and ud.isFactory
end

local function updateQuotaNumber(builderID, unitDefID, quantity)
	if WG.Quotas then
		local quotas = WG.Quotas.getQuotas()
		quotas[builderID] = quotas[builderID] or {}
		quotas[builderID][unitDefID] = quotas[builderID][unitDefID] or 0
		quotas[builderID][unitDefID] = math.max(quotas[builderID][unitDefID] + (quantity or 0), 0)
		if quantity > 0 then
			Spring.PlaySoundFile(CONFIG.sound_queue_add, 0.75, "ui")
		else
			Spring.PlaySoundFile(CONFIG.sound_queue_rem, 0.75, "ui")
		end
	end
end

-- Intercept build commands
function widget:CommandNotify(cmdID, params, options)
  if not heldMeta then
    return false
  end

  if (cmdID and cmdID < 0) then
    local selected = Spring.GetSelectedUnits()
    for i = 1, #selected do
      local unitID = selected[i]
      local unitDefID = Spring.GetUnitDefID(unitID)
      if IsFactory(unitDefID) then
        local buildUnitDefID = -cmdID
        local quantity = 1
        if options.shift then quantity = 5 end
        if options.ctrl then quantity = 20 end
        if options.alt then quantity = 1000 end
        if options.right then quantity = -quantity end

        updateQuotaNumber(unitID, buildUnitDefID, quantity)
        return true -- Command consumed
      end
    end
  end

  return false
end
