local widget = widget ---@type Widget

function widget:GetInfo()
	return {
		name = "Scroll Queue",
		desc = "Use the mouse wheel to add/remove units from the factory build queue while hovering the build menu",
		author = "uBdead",
		date = "June 2026",
		license = "GNU GPL, v2 or later",
		layer = 0,
		enabled = true,
	}
end

--------------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------------
local CONFIG = {
	sound_queue_add = "LuaUI/Sounds/buildbar_add.wav",
	sound_queue_rem = "LuaUI/Sounds/buildbar_rem.wav",
}

--------------------------------------------------------------------------------
-- Localized Spring API
--------------------------------------------------------------------------------
local spGetSelectedUnits = Spring.GetSelectedUnits
local spGetUnitDefID = Spring.GetUnitDefID
local spGetModKeyState = Spring.GetModKeyState
local spGiveOrderToUnit = Spring.GiveOrderToUnit
local spPlaySoundFile = Spring.PlaySoundFile

--------------------------------------------------------------------------------
-- Lookup tables
--------------------------------------------------------------------------------
local factories = {}    -- factory unitDefID -> true
local buildOptions = {} -- factory unitDefID -> { [buildableUnitDefID] = true }

for unitDefID, unitDef in pairs(UnitDefs) do
	if unitDef.isFactory then
		factories[unitDefID] = true
		local options = {}
		for _, buildableDefID in ipairs(unitDef.buildOptions) do
			options[buildableDefID] = true
		end
		buildOptions[unitDefID] = options
	end
end

local function buildOrderOptions(remove, alt, ctrl, shift)
	local opts = {}
	if remove then
		opts[#opts + 1] = "right"
	end
	if alt then
		opts[#opts + 1] = "alt"
	end
	if ctrl then
		opts[#opts + 1] = "ctrl"
	end
	if shift then
		opts[#opts + 1] = "shift"
	end
	return opts
end

--------------------------------------------------------------------------------
-- Callins
--------------------------------------------------------------------------------
function widget:MouseWheel(up, value)
	local buildmenu = WG["buildmenu"]
	if not buildmenu or not buildmenu.hoverID or buildmenu.hoverID <= 0 then
		return false
	end

	local hoverDefID = buildmenu.hoverID
	local alt, ctrl, _, shift = spGetModKeyState()
	local opts = buildOrderOptions(not up, alt, ctrl, shift)
	local issued = false

	for _, unitID in ipairs(spGetSelectedUnits()) do
		local unitDefID = spGetUnitDefID(unitID)
		if factories[unitDefID] and buildOptions[unitDefID][hoverDefID] then
			spGiveOrderToUnit(unitID, -hoverDefID, {}, opts)
			issued = true
		end
	end

	if issued then
		spPlaySoundFile(up and CONFIG.sound_queue_add or CONFIG.sound_queue_rem, 0.75, "ui")
		return true
	end

	return false
end
