if not RmlUi then
	return false
end

-- Load icontypes table from BAR.sdd/gamedata/icontypes.lua
local icontypes = VFS.Include("gamedata/icontypes.lua")

local widget = widget ---@type Widget

function widget:GetInfo()
	return {
		name = "gui_event_log",
		desc = "Generated RML widget template",
		author = "Generated from rml_starter/generate-widget.sh",
		date = "2025",
		license = "GNU GPL, v2 or later",
		layer = -1000000,
		enabled = true,
	}
end

local nukers = {}
local gaiaTeamID = Spring.GetGaiaTeamID()
local ourTeamID = Spring.GetMyTeamID()
local spIsUnitAllied = Spring.IsUnitAllied
local unitOfInterest = {} -- unitDefID
local gameOver = false;
local hasSeenT2 = false
local hasSeenT3 = false
local constructorDefIDs = {}
local idleConstructors = {}

-- Update the list of idle constructor units
local function updateList()
	for unitID, _ in pairs(idleConstructors) do
		idleConstructors[unitID] = nil
	end
	local myTeamID = Spring.GetLocalTeamID and Spring.GetLocalTeamID() or Spring.GetMyTeamID()
	for unitID, unitDefID in pairs(Spring.GetAllUnits and Spring.GetAllUnits() or {}) do
		if constructorDefIDs[unitDefID] and Spring.GetUnitTeam(unitID) == myTeamID then
			if not Spring.GetUnitIsDead(unitID) and not Spring.GetUnitIsBeingBuilt(unitID) then
				local queue = Spring.GetUnitCommandCount(unitID) or 0
				if queue == 0 then
					idleConstructors[unitID] = true
				end
			end
		end
	end
end

-- Commander under attack logic
local isCommander = {}
local commanderAlarmInterval = 10 -- seconds
local lastCommanderAlarmTime = Spring.GetTimer()
local spGetTimer = Spring.GetTimer
local spDiffTimers = Spring.DiffTimers
local spGetLocalTeamID = Spring.GetLocalTeamID
local localTeamID = nil

-- Constants
local WIDGET_NAME = "gui_event_log"
local MODEL_NAME = "gui_event_log_model"
local RML_PATH = "LuaUI/Widgets/gui_event_log/gui_event_log.rml"

-- Widget state
local document
local dm_handle

local init_model
local lastEventAdded

local function click(index)
	local clickedItem = init_model.events[index + 1]
	local x, y, z = nil, nil, nil
	if clickedItem.unitid then
		x, y, z = Spring.GetUnitPosition(clickedItem.unitid)
	end
	if clickedItem.unitid and x and z then
		if (Spring.IsUnitSelected(clickedItem.unitid)) then
			if x and z then
				Spring.SetCameraTarget(x, y, z)
			end
			return
		end
		Spring.SelectUnit(clickedItem.unitid)
		return
	end
	if clickedItem.point then
		Spring.SetCameraTarget(clickedItem.point.x, 0, clickedItem.point.z)
	end
end

-- Initial data model
init_model = {
	debugMode = false,
	events = {},
	eventclick = function(ev, i)
		-- Spring.Echo("ev parameters:", ev.parameters.button)
		click(i)
	end,
	settechlevel = function(ev, level)
		dm_handle.techlevel = level
		Spring.Echo("Set Tech Level filter to " .. tostring(level))
	end,
	currentFrame = 0,
	techlevel = 1,
}

local function AddEvent(event)
	if gameOver then
		return
	end
	if event.frame == nil then
		event.frame = Spring.GetGameFrame()
	end
	if event.multiplier == nil then
		event.multiplier = 1
	end
	if event.duration == nil then
		event.duration = 60 -- seconds
	end

	lastEventAdded = event

	-- check if we are having the same event (same message, similar position)
	for i, existing_event in ipairs(init_model.events) do
		if existing_event.message == event.message then
			local dx, dz = 0, 0
			if existing_event.point and event.point then
				dx = existing_event.point.x - event.point.x
				dz = existing_event.point.z - event.point.z
			end
			local dist2 = dx * dx + dz * dz
			if dist2 < 2000 * 2000 then -- within 2000 units
				-- just increase the multiplier and update the frame
				existing_event.multiplier = (existing_event.multiplier or 1) + 1
				existing_event.frame = event.frame
				if event.point then
					existing_event.point = event.point -- update to the latest position
				end
				if event.unitid then
					existing_event.unitid = event.unitid -- update to the latest unitid
				end
				if event.icon then
					existing_event.icon = event.icon -- update to the latest icon
				end

				dm_handle.events = init_model.events
				return
			end
		end
	end

	table.insert(init_model.events, 1, event)
	if #init_model.events > 25 then
		table.remove(init_model.events) -- Remove the oldest event, keep only the latest 25 events
	end
	dm_handle.events = init_model
		.events -- TODO: ideally we just manipulate dm_handle directly and it would update the UI, but how?
end

function widget:Initialize()
	if widget:GetInfo().enabled == false then
		Spring.Echo(WIDGET_NAME .. ": Widget is disabled, skipping initialization")
		return false
	end

	Spring.Echo(WIDGET_NAME .. ": Initializing widget...")

	for k, v in pairs(UnitDefs) do
		if v.customParams.unitgroup == "nuke" then
			nukers[k] = true
		end
		if v.customParams and v.customParams.iscommander then
			isCommander[k] = true
		end
		if v.canAssist and not v.isFactory then
			constructorDefIDs[k] = true
		end
	end

	-- Get the shared RML context
	widget.rmlContext = RmlUi.GetContext("shared")
	if not widget.rmlContext then
		Spring.Echo(WIDGET_NAME .. ": ERROR - Failed to get RML context")
		return false
	end

	-- Create and bind the data model
	dm_handle = widget.rmlContext:OpenDataModel(MODEL_NAME, init_model)
	if not dm_handle then
		Spring.Echo(WIDGET_NAME .. ": ERROR - Failed to create data model")
		return false
	end

	Spring.Echo(WIDGET_NAME .. ": Data model created successfully")

	-- Load the RML document
	document = widget.rmlContext:LoadDocument(RML_PATH, widget)
	if not document then
		Spring.Echo(WIDGET_NAME .. ": ERROR - Failed to load document: " .. RML_PATH)
		widget:Shutdown()
		return false
	end

	-- Apply styles and show the document
	document:ReloadStyleSheet()
	document:Show()
	Spring.Echo(WIDGET_NAME .. ": Widget initialized successfully")

	-- RmlUi.SetDebugContext('shared')

	return true
end

function widget:Shutdown()
	Spring.Echo(WIDGET_NAME .. ": Shutting down widget...")

	-- Clean up data model
	if widget.rmlContext and dm_handle then
		widget.rmlContext:RemoveDataModel(MODEL_NAME)
		dm_handle = nil
	end

	-- Close document
	if document then
		document:Close()
		document = nil
	end

	widget.rmlContext = nil
	Spring.Echo(WIDGET_NAME .. ": Shutdown complete")
end

-- Widget functions callable from RML
function widget:Reload()
	Spring.Echo(WIDGET_NAME .. ": Reloading widget...")
	widget:Shutdown()
	widget:Initialize()
end

function widget:ToggleDebugger()
	if dm_handle then
		dm_handle.debugMode = not dm_handle.debugMode

		if dm_handle.debugMode then
			RmlUi.SetDebugContext('shared')
			Spring.Echo(WIDGET_NAME .. ": RmlUi debugger enabled")
		else
			RmlUi.SetDebugContext(nil)
			Spring.Echo(WIDGET_NAME .. ": RmlUi debugger disabled")
		end
	end
end

function widget:GameStarted()
	AddEvent({
		message = "Game started",
		type = "neutral",
		icon = "/icons/info.png"
	})
end

function widget:GameFrame(frame)
	dm_handle.currentFrame = frame
	updateList() -- TODO: probably not every frame needed
end

function widget:StockpileChanged(unitID, unitDefID, unitTeam, weaponNum, oldCount, newCount)
	if nukers[unitDefID] and oldCount == 0 and newCount > 0 then
		AddEvent({ message = "Nuclear Missile Ready", type = "good", icon = "/icons/nuke.png", unitid = unitID })
	end
end

function widget:UnitDestroyed(unitID, unitDefID, unitTeam, attackerID, attackerDefID, attackerTeam)
	if not spIsUnitAllied(unitID) then
		if isCommander[unitDefID] then
			local unitDef = UnitDefs[unitDefID]
			local iconType = unitDef and unitDef.iconType
			local iconName = iconType and icontypes[iconType] and icontypes[iconType].bitmap
			local iconPath = iconName and ("/" .. iconName) or "/icons/empty.png"
			local x, y, z = Spring.GetUnitPosition(unitID)

			AddEvent({
				message = "Enemy Commander destroyed!",
				type = "bad",
				icon = iconPath,
				point = { x = x, z = z }
			})
		end
		return
	else
		if isCommander[unitDefID] then
			local unitDef = UnitDefs[unitDefID]
			local iconType = unitDef and unitDef.iconType
			local iconName = iconType and icontypes[iconType] and icontypes[iconType].bitmap
			local iconPath = iconName and ("/" .. iconName) or "/icons/empty.png"
			local x, y, z = Spring.GetUnitPosition(unitID)

			AddEvent({
				message = "Allied Commander destroyed!",
				type = "terrible",
				icon = iconPath,
				point = { x = x, z = z }
			})
		end
	end

	-- Remove from idleConstructors if present
	idleConstructors[unitID] = nil

	local unitDef = UnitDefs[unitDefID]
	local techlevel = unitDef and unitDef.customParams and tonumber(unitDef.customParams.techlevel) or nil
	if techlevel < dm_handle.techlevel then
		return
	end

	local iconType = unitDef and unitDef.iconType
	local iconName = iconType and icontypes[iconType] and icontypes[iconType].bitmap
	local iconPath = iconName and ("/" .. iconName) or "/icons/empty.png"

	-- check if its a unit or structure
	local message = "Unit lost"
	if unitDef and unitDef.isBuilding then
		message = "Structure lost"
	end

	local event = {
		message = message,
		type = "bad",
		icon = iconPath,
	}

	local x, y, z = Spring.GetUnitPosition(unitID)
	if x and z then
		event.point = { x = x, z = z }
	end

	AddEvent(event)
end

function widget:UnitEnteredLos(unitID, unitTeam)
	if spIsUnitAllied(unitID) or unitTeam == gaiaTeamID then
		return
	end

	local unitDefID = Spring.GetUnitDefID(unitID)
	local unitDef = unitDefID and UnitDefs[unitDefID]
	if not unitDef then return end
	local techlevel = unitDef and unitDef.customParams and tonumber(unitDef.customParams.techlevel) or nil
	if unitDef.isBuilding then
		if not hasSeenT2 and techlevel and techlevel == 2 then
			hasSeenT2 = true
			local iconType = unitDef and unitDef.iconType
			local iconName = iconType and icontypes[iconType] and icontypes[iconType].bitmap
			local iconPath = iconName and ("/" .. iconName) or "/icons/empty.png"
			local x, y, z = Spring.GetUnitPosition(unitID)
			AddEvent({ message = "Enemy T2 Building Spotted", type = "neutral", icon = iconPath, point = { x = x, z = z } })
		end

		if not hasSeenT3 and techlevel and techlevel == 3 then
			hasSeenT3 = true
			local iconType = unitDef and unitDef.iconType
			local iconName = iconType and icontypes[iconType] and icontypes[iconType].bitmap
			local iconPath = iconName and ("/" .. iconName) or "/icons/empty.png"
			local x, y, z = Spring.GetUnitPosition(unitID)
			AddEvent({ message = "Enemy T3 Building Spotted", type = "neutral", icon = iconPath, point = { x = x, z = z } })
		end

		return
	end

	if techlevel < dm_handle.techlevel and not isCommander[unitDefID] then
		return
	end

	local iconType = unitDef and unitDef.iconType
	local iconName = iconType and icontypes[iconType] and icontypes[iconType].bitmap
	local iconPath = iconName and ("/" .. iconName) or "/icons/empty.png"
	local x, y, z = Spring.GetUnitPosition(unitID)
	local prefix = ""

	if techlevel and techlevel > 1 then
		prefix = " T" .. techlevel
	end

	local message = "Enemy" .. prefix .. " Spotted"
	AddEvent({ message = message, type = "bad", icon = iconPath, point = { x = x, z = z } })
end

function widget:GameOver()
	AddEvent({
		message = "Game Over",
		type = "neutral",
		icon = "/icons/info.png"
	})
	gameOver = true
end

local function CommanderDamaged(unitID, unitDefID, unitTeam, damage, paralyzer)
	if not isCommander[unitDefID] then return false end

	local now = spGetTimer()
	if spDiffTimers(now, lastCommanderAlarmTime) < commanderAlarmInterval then return end
	lastCommanderAlarmTime = now

	local unitDef = UnitDefs[unitDefID]
	local iconType = unitDef and unitDef.iconType
	local iconName = iconType and icontypes[iconType] and icontypes[iconType].bitmap
	local iconPath = iconName and ("/" .. iconName) or "/icons/empty.png"
	local event = {
		message = "Commander under attack!",
		type = "bad",
		icon = iconPath,
		unitid = unitID,
	}

	AddEvent(event)
	return true
end

-- Commander under attack event
function widget:UnitDamaged(unitID, unitDefID, unitTeam, damage, paralyzer)
	if localTeamID == nil then localTeamID = spGetLocalTeamID() end
	if unitTeam ~= localTeamID then return false end
	if damage < 10 then return end

	if CommanderDamaged(unitID, unitDefID, unitTeam, damage, paralyzer) then
		return
	end

	local unitDef = UnitDefs[unitDefID]
	local techlevel = unitDef and unitDef.customParams and tonumber(unitDef.customParams.techlevel) or nil

	if techlevel < dm_handle.techlevel then
		return
	end


	local iconType = unitDef and unitDef.iconType
	local iconName = iconType and icontypes[iconType] and icontypes[iconType].bitmap
	local iconPath = iconName and ("/" .. iconName) or "/icons/empty.png"
	local x, y, z = Spring.GetUnitPosition(unitID)

	AddEvent({
		message = "Unit under attack",
		type = "bad",
		icon = iconPath,
		unitid = unitID,
		point = { x = x, z = z }
	})
end

-- Handle spacebar press when no units are selected
function widget:KeyPress(key, mods, isRepeat, label, unicode)
	if not lastEventAdded then return false end
	-- 32 is the keycode for spacebar
	if key == 32 and Spring.GetSelectedUnitsCount() == 0 then
		local x, y, z = nil, nil, nil
		if lastEventAdded and lastEventAdded.unitid then
			x, y, z = Spring.GetUnitPosition(lastEventAdded.unitid)
		end
		if x and y then -- unit is still alive
			Spring.SetCameraTarget(x, y, z)
			Spring.SelectUnit(lastEventAdded.unitid)
			return true
		end
		if lastEventAdded and lastEventAdded.point then
			Spring.SetCameraTarget(lastEventAdded.point.x, 0, lastEventAdded.point.z)
			return true
		end

		-- go to the an idle constructor if any
		for unitID, _ in pairs(idleConstructors) do
			x, y, z = Spring.GetUnitPosition(unitID)
			if x and y then -- unit is still alive
				Spring.SetCameraTarget(x, y, z)
				Spring.SelectUnit(unitID)
				return true
			else
				idleConstructors[unitID] = nil -- remove dead unit from the list
			end
		end
	end
end

function widget:UnitIdle(unitID, unitDefID, unitTeam)
	if unitTeam ~= ourTeamID then
		return
	end

	if constructorDefIDs[unitDefID] and spIsUnitAllied(unitID) then
		local unitDef = UnitDefs[unitDefID]
		local iconType = unitDef and unitDef.iconType
		local iconName = iconType and icontypes[iconType] and icontypes[iconType].bitmap
		local iconPath = iconName and ("/" .. iconName) or "/icons/empty.png"
		local x, y, z = Spring.GetUnitPosition(unitID)
		-- add the tech level
		local techlevel = unitDef and unitDef.customParams and tonumber(unitDef.customParams.techlevel) or nil

		if techlevel < dm_handle.techlevel then
			return
		end

		local prefix = ""
		if techlevel and techlevel > 1 then
			prefix = "T" .. techlevel .. " "
		end

		AddEvent({
			message = prefix .. "Constructor idle",
			type = "neutral",
			icon = iconPath,
			unitid = unitID,
			point = { x = x, z = z }
		})
		idleConstructors[unitID] = true
	end
end

function widget:UnitCommand(unitID, unitDefID, unitTeam, cmdID, cmdParams, cmdOptions, cmdTag)
	-- Remove from idleConstructors if present (unit is no longer idle)
	if idleConstructors[unitID] then
		idleConstructors[unitID] = nil
	end
end

function widget:UnitGiven(unitID, unitDefID, newTeam, oldTeam)
	idleConstructors[unitID] = nil
end

function widget:UnitTaken(unitID, unitDefID, oldTeam, newTeam)
	idleConstructors[unitID] = nil
end
