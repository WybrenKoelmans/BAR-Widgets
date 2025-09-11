local widget = widget ---@type Widget

function widget:GetInfo()
	return {
		name = "Builders Are Lazy",
		desc = "Builders will idle instead of guarding after building (to become available from the idle mechanic)",
		author = "uBdead (using code from other widgets)",
		date = "June 2025",
		license = "GNU GPL, v2 or later",
		layer = 50,
		enabled = true,
		handler = true,
	}
end

local CMD_REPAIR = CMD.REPAIR
local CMD_GUARD = CMD.GUARD
local CMD_MOVE = CMD.MOVE

local IsUnitAllied = Spring.IsUnitAllied
local GiveOrderToUnit = Spring.GiveOrderToUnit
local GetUnitCommands = Spring.GetUnitCommands
local myTeamID = Spring.GetMyTeamID()

local gameStarted

local hasRepair = {}
for udid, ud in pairs(UnitDefs) do
	if ud.canRepair then
		hasRepair[udid] = true
	end
end

local function maybeRemoveSelf()
	if Spring.GetSpectatingState() and (Spring.GetGameFrame() > 0 or gameStarted) then
		widgetHandler:RemoveWidget()
		return true
	end
end

local function maybeDisableOthers()
	if widgetHandler:IsWidgetKnown("Idle Constructor Guard After Build") then
		Spring.Echo("Disabling widget 'Idle Constructor Guard After Build' to prevent conflicts with 'BuildersAreLazy'")
		widgetHandler:DisableWidget("Idle Constructor Guard After Build")
	end
	if widgetHandler:IsWidgetKnown("Guard damaged constructors") then
		Spring.Echo("Disabling widget 'Guard damaged constructors' to prevent conflicts with 'BuildersAreLazy'")
		widgetHandler:DisableWidget("Guard damaged constructors")
	end
end

local function RemoveGuardCommand(unitID)
	Spring.Echo("Removing guard command from unit " .. unitID)
	local queue = GetUnitCommands(unitID, 4)
	--  loop the queue
	for i = 1, #queue do
		Spring.Echo("Checking command " .. i .. " with id " .. queue[i].id)
		local cmd = queue[i]
		if cmd.id == CMD_GUARD then
			GiveOrderToUnit(unitID, CMD.REMOVE, { cmd.tag }, 0)
			return
		end
	end
end

function widget:GameStart()
	maybeRemoveSelf()
	gameStarted = true
end

function widget:PlayerChanged(playerID)
	maybeRemoveSelf()
end

function widget:Initialize()
	if Spring.IsReplay() or Spring.GetGameFrame() > 0 then
		if maybeRemoveSelf() then return end
	end

	maybeDisableOthers()
end

function widget:DefaultCommand(type, id, cmd)
	-- check if the current command is to guard
	if cmd ~= CMD_GUARD then
		return
	end

	-- check if the unit is allied
	if not IsUnitAllied(id) then
		return
	end

	local unitHealth, maxHealth = Spring.GetUnitHealth(id)
	-- check if the unit is at 100% hp
	if unitHealth ~= nil and maxHealth ~= nil and unitHealth < maxHealth then
		if hasRepair[unitDefID] then
			return CMD_REPAIR
		end
	end

	return CMD_MOVE
end

function widget:UnitFromFactory(unitID, unitDefID, unitTeam, factID, factDefID, userOrders)
	if unitTeam ~= myTeamID then
		return
	end
	if (userOrders) then
		return
	end

	if hasRepair[unitDefID] then
		RemoveGuardCommand(unitID)
	end
end

function widget:Shutdown()
	-- Restore the incompatible widgets
	if widgetHandler:IsWidgetKnown("Idle Constructor Guard After Build") then
		widgetHandler:EnableWidget("Idle Constructor Guard After Build")
		Spring.Echo("Re-enabling widget 'Idle Constructor Guard After Build'")
	end
	if widgetHandler:IsWidgetKnown("Guard damaged constructors") then
		widgetHandler:EnableWidget("Guard damaged constructors")
		Spring.Echo("Re-enabling widget 'Guard damaged constructors'")
	end
end
