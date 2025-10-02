if not RmlUi then
	return false
end

local widget = widget ---@type Widget

-- Load icontypes table from BAR.sdd/gamedata/icontypes.lua
local icontypes = VFS.Include("gamedata/icontypes.lua")

function widget:GetInfo()
	return {
		name = "BattleLog",
		desc = "Displays important battle events in a log",
		author = "uBdead",
		date = "2025",
		license = "GNU GPL, v2 or later",
		layer = -1000000,
		enabled = true,
	}
end

local nukers = {}

local spEcho = Spring.Echo
local spGetGaiaTeamID = Spring.GetGaiaTeamID
local spGetMyTeamID = Spring.GetMyTeamID
local spIsUnitAllied = Spring.IsUnitAllied
local spGetAllUnits = Spring.GetAllUnits
local spGetUnitTeam = Spring.GetUnitTeam
local spGetUnitIsDead = Spring.GetUnitIsDead
local spGetUnitIsBeingBuilt = Spring.GetUnitIsBeingBuilt
local spGetUnitCommandCount = Spring.GetUnitCommandCount
local spGetTimer = Spring.GetTimer
local spDiffTimers = Spring.DiffTimers
local spGetLocalTeamID = Spring.GetLocalTeamID
local spGetUnitPosition = Spring.GetUnitPosition
local spIsUnitSelected = Spring.IsUnitSelected
local spSetCameraTarget = Spring.SetCameraTarget
local spSelectUnit = Spring.SelectUnit
local spGetGameFrame = Spring.GetGameFrame
local spGetUnitDefID = Spring.GetUnitDefID
local spGetSelectedUnitsCount = Spring.GetSelectedUnitsCount

local unitDefIDCache = {}
local function GetUnitDefID(unitID)
	if unitDefIDCache[unitID] then
		return unitDefIDCache[unitID]
	end
	local unitDefID = spGetUnitDefID(unitID)
	if unitDefID then
		unitDefIDCache[unitID] = unitDefID
	end
	return unitDefID
end

local gaiaTeamID = spGetGaiaTeamID()
local ourTeamID = spGetMyTeamID()
local myTeamID = spGetLocalTeamID and spGetLocalTeamID() or ourTeamID -- Cache team ID
local unitOfInterest = {
	armanni = true,
	armarad = true,
	armbanth = true,
	armbrtha = true,
	armrad = true,
	armsilo = true,
	armthor = true,
	armvulcan = true,
	corarad = true,
	corbuzz = true,
	cordoom = true,
	corinth = true,
	corjugg = true,
	corkorg = true,
	corrad = true,
	corsilo = true,
	legarad = true,
	legrad = true,
	corcom = true,
	armcom = true,
	legcom = true,
} -- unitDefID

local gameOver = false;
local hasSeenT2 = false
local hasSeenT3 = false
local constructorDefIDs = {}
local idleConstructors = {}
local lastRemovalCheckFrame = 0

-- Update the list of idle constructor units
local function updateList()
	-- Clear dead units from cache efficiently
	for unitID in pairs(idleConstructors) do
		if spGetUnitIsDead(unitID) then
			idleConstructors[unitID] = nil
			unitDefIDCache[unitID] = nil
		end
	end

	local allUnits = spGetAllUnits and spGetAllUnits() or {}

	for _, unitID in ipairs(allUnits) do
		local unitDefID = GetUnitDefID(unitID)
		if unitDefID and constructorDefIDs[unitDefID] and spGetUnitTeam(unitID) == myTeamID then
			if not spGetUnitIsDead(unitID) and not spGetUnitIsBeingBuilt(unitID) then
				local queue = spGetUnitCommandCount(unitID) or 0
				if queue == 0 then
					idleConstructors[unitID] = true
				else
					idleConstructors[unitID] = nil
				end
			end
		end
	end
end

-- Commander under attack logic
local isCommander = {}
local commanderAlarmInterval = 10 -- seconds
local lastCommanderAlarmTime = spGetTimer()

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
		x, y, z = spGetUnitPosition(clickedItem.unitid)
	end
	if clickedItem.unitid and x and y and z then
		if (spIsUnitSelected(clickedItem.unitid)) then
			spSetCameraTarget(x, y, z)
			return
		end
		spSelectUnit(clickedItem.unitid)
		return
	end
	if clickedItem.point then
		spSetCameraTarget(clickedItem.point.x, 0, clickedItem.point.z)
	end
end

-- Initial data model
init_model = {
	debugMode = false,
	events = {},
	eventclick = function(ev, i)
		-- spEcho("ev parameters:", ev.parameters.button)
		click(i)
	end,
	settechlevel = function(ev, level)
		dm_handle.techlevel = level
		spEcho("Set Tech Level filter to " .. tostring(level))
	end,
	currentFrame = 0,
	techlevel = 1,
}

local function AddEvent(event)
	if gameOver then
		return
	end
	if event.frame == nil then
		event.frame = spGetGameFrame()
	end
	if event.multiplier == nil then
		event.multiplier = 1
	end
	if event.duration == nil then
		event.duration = 60 -- seconds
	end

	lastEventAdded = event

	-- Reverted optimization: check all events for deduplication
	for i = 1, #init_model.events do
		local existing_event = init_model.events[i]
		if existing_event.message == event.message then
			local withinDistance = true
			if existing_event.point and event.point then
				local dx = existing_event.point.x - event.point.x
				local dz = existing_event.point.z - event.point.z
				-- Use squared distance to avoid sqrt calculation
				local dist2 = dx * dx + dz * dz
				withinDistance = dist2 < 4000000 -- 2000^2
			end

			if withinDistance then
				-- Update existing event
				existing_event.multiplier = (existing_event.multiplier or 1) + 1
				existing_event.frame = event.frame
				if event.point then
					existing_event.point = event.point
				end
				if event.unitid then
					existing_event.unitid = event.unitid
				end
				if event.icon then
					existing_event.icon = event.icon
				end
				dm_handle.events = init_model.events
				return
			end
		end
	end

	table.insert(init_model.events, 1, event)
	if #init_model.events > 25 then
		table.remove(init_model.events) -- Remove the oldest event
	end
	dm_handle.events = init_model.events
end

function widget:Initialize()
	if widget:GetInfo().enabled == false then
		spEcho(WIDGET_NAME .. ": Widget is disabled, skipping initialization")
		return false
	end

	spEcho(WIDGET_NAME .. ": Initializing widget...")

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

		-- check if the unitdef name is in the unitOfInterest list, then replace it with its id
		if unitOfInterest[v.name] then
			unitOfInterest[k] = { translatedHumanName = v.translatedHumanName or v.name or "Unit" }
			unitOfInterest[v.name] = nil
		end
	end

	-- Get the shared RML context
	widget.rmlContext = RmlUi.GetContext("shared")
	if not widget.rmlContext then
		spEcho(WIDGET_NAME .. ": ERROR - Failed to get RML context")
		return false
	end

	-- Create and bind the data model
	dm_handle = widget.rmlContext:OpenDataModel(MODEL_NAME, init_model)
	if not dm_handle then
		spEcho(WIDGET_NAME .. ": ERROR - Failed to create data model")
		return false
	end

	spEcho(WIDGET_NAME .. ": Data model created successfully")

	-- Load the RML document
	document = widget.rmlContext:LoadDocument(RML_PATH, widget)
	if not document then
		spEcho(WIDGET_NAME .. ": ERROR - Failed to load document: " .. RML_PATH)
		widget:Shutdown()
		return false
	end

	-- Apply styles and show the document
	document:ReloadStyleSheet()
	document:Show()
	spEcho(WIDGET_NAME .. ": Widget initialized successfully")

	-- RmlUi.SetDebugContext('shared')

	return true
end

function widget:UnitCreated(unitID, unitDefID, unitTeam, builderID, reason, silent)
	unitDefIDCache[unitID] = unitDefID

	local unitDef = UnitDefs[unitDefID] -- TODO cache these?
	if not unitDef.isFactory then
		return
	end

	if not spIsUnitAllied(unitID) then
		return
	end

	local name = unitDef.translatedHumanName or unitDef.name or "Factory"
	local iconType = unitDef and unitDef.iconType
	local iconName = iconType and icontypes[iconType] and icontypes[iconType].bitmap
	local iconPath = iconName and ("/" .. iconName) or "/icons/empty.png"
	local x, y, z = spGetUnitPosition(unitID)

	local event = {
		message = name .. " under construction.",
		type = "good",
		icon = iconPath,
		point = { x = x, z = z }
	}
	if (unitTeam == myTeamID) then
		event.unitid = unitID
	end

	AddEvent(event)
end

function widget:UnitFinished(unitID, unitDefID, unitTeam)
	unitDefIDCache[unitID] = unitDefID

	if not spIsUnitAllied(unitID) then
		return
	end

	local unitDef = UnitDefs[unitDefID]
	if not unitDef.isFactory then
		return
	end

	local name = unitDef.translatedHumanName or unitDef.name or "Unit"
	local iconType = unitDef and unitDef.iconType
	local iconName = iconType and icontypes[iconType] and icontypes[iconType].bitmap
	local iconPath = iconName and ("/" .. iconName) or "/icons/empty.png"
	local x, y, z = spGetUnitPosition(unitID)

	local event = {
		message = name .. " completed.",
		type = "good",
		icon = iconPath,
		point = { x = x, z = z }
	}
	if (unitTeam == myTeamID) then
		event.unitid = unitID
	end

	AddEvent(event)
end

function widget:Shutdown()
	spEcho(WIDGET_NAME .. ": Shutting down widget...")

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
	spEcho(WIDGET_NAME .. ": Shutdown complete")
end

-- Widget functions callable from RML
function widget:Reload()
	spEcho(WIDGET_NAME .. ": Reloading widget...")
	widget:Shutdown()
	widget:Initialize()
end

function widget:ToggleDebugger()
	if dm_handle then
		dm_handle.debugMode = not dm_handle.debugMode

		if dm_handle.debugMode then
			RmlUi.SetDebugContext('shared')
			spEcho(WIDGET_NAME .. ": RmlUi debugger enabled")
		else
			RmlUi.SetDebugContext(nil)
			spEcho(WIDGET_NAME .. ": RmlUi debugger disabled")
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
	-- Only update idle constructors every 30 frames (1 second at 30fps)
	if frame % 30 == 0 then
		updateList()
	end

	-- Periodically clean up old events
	if frame - lastRemovalCheckFrame >= 150 then -- every 5 seconds at 30
		local beforeEvents = #init_model.events
		lastRemovalCheckFrame = frame
		local currentTime = spGetGameFrame()
		local i = 1
		while i <= #init_model.events do
			local event = init_model.events[i]
			if event.frame and event.duration then
				local ageInFrames = currentTime - event.frame
				if ageInFrames > (event.duration * 30) then -- Convert duration from seconds to frames
					table.remove(init_model.events, i)
				else
					i = i + 1
				end
			else
				i = i + 1
			end
		end
		dm_handle.events = init_model.events
		local afterEvents = #init_model.events
		Spring.Echo(WIDGET_NAME ..
		": Removed " .. (beforeEvents - afterEvents) .. " old events, " .. afterEvents .. " remain.")
	end
end

function widget:StockpileChanged(unitID, unitDefID, unitTeam, weaponNum, oldCount, newCount)
	if nukers[unitDefID] then
		if oldCount == 0 and newCount > 0 then
			AddEvent({ message = "Nuclear Missile Ready", type = "good", icon = "/icons/nuke.png", unitid = unitID })
		elseif oldCount > 0 and newCount < oldCount then
			AddEvent({ message = "Nuclear Missile Launched", type = "good", icon = "/icons/nuke.png", unitid = unitID })
		end
	end
end

function widget:UnitDestroyed(unitID, unitDefID, unitTeam, attackerID, attackerDefID, attackerTeam)
	unitDefIDCache[unitID] = nil
	if not spIsUnitAllied(unitID) then
		if isCommander[unitDefID] then
			local unitDef = UnitDefs[unitDefID]
			local iconType = unitDef and unitDef.iconType
			local iconName = iconType and icontypes[iconType] and icontypes[iconType].bitmap
			local iconPath = iconName and ("/" .. iconName) or "/icons/empty.png"
			local x, y, z = spGetUnitPosition(unitID)

			AddEvent({
				message = "Enemy Commander destroyed!",
				type = "good",
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
			local x, y, z = spGetUnitPosition(unitID)

			AddEvent({
				message = "Allied Commander destroyed!",
				type = "terrible",
				icon = iconPath,
				point = { x = x, z = z }
			})
		end
	end

	if unitTeam ~= ourTeamID then
		return
	end

	-- Remove from idleConstructors if present
	idleConstructors[unitID] = nil

	local unitDef = UnitDefs[unitDefID]
	local techlevel = unitDef and unitDef.customParams and tonumber(unitDef.customParams.techlevel) or nil
	if techlevel < dm_handle.techlevel and not unitOfInterest[unitDefID] and not unitDef.isFactory then
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
	if unitOfInterest[unitDefID] and unitOfInterest[unitDefID].translatedHumanName then
		message = unitOfInterest[unitDefID].translatedHumanName .. " lost"
	end

	local event = {
		message = message,
		type = "bad",
		icon = iconPath,
	}

	local x, y, z = spGetUnitPosition(unitID)
	if x and z then
		event.point = { x = x, z = z }
	end

	AddEvent(event)
end

function widget:UnitEnteredLos(unitID, unitTeam)
	if spIsUnitAllied(unitID) or unitTeam == gaiaTeamID then
		return
	end

	local unitDefID = GetUnitDefID(unitID)
	local unitDef = unitDefID and UnitDefs[unitDefID]
	if not unitDef then return end
	local techlevel = unitDef and unitDef.customParams and tonumber(unitDef.customParams.techlevel) or nil
	if unitDef.isBuilding then
		if not hasSeenT2 and techlevel and techlevel == 2 then
			hasSeenT2 = true
			local iconType = unitDef and unitDef.iconType
			local iconName = iconType and icontypes[iconType] and icontypes[iconType].bitmap
			local iconPath = iconName and ("/" .. iconName) or "/icons/empty.png"
			local x, y, z = spGetUnitPosition(unitID)
			local message = "Enemy T2 Building Spotted"
			if unitOfInterest[unitDefID] and unitOfInterest[unitDefID].translatedHumanName then
				message = unitOfInterest[unitDefID].translatedHumanName .. " Spotted"
			end
			AddEvent({ message = message, type = "neutral", icon = iconPath, point = { x = x, z = z } })
		end

		if not hasSeenT3 and techlevel and techlevel == 3 then
			hasSeenT3 = true
			local iconType = unitDef and unitDef.iconType
			local iconName = iconType and icontypes[iconType] and icontypes[iconType].bitmap
			local iconPath = iconName and ("/" .. iconName) or "/icons/empty.png"
			local x, y, z = spGetUnitPosition(unitID)
			local message = "Enemy T3 Building Spotted"
			if unitOfInterest[unitDefID] and unitOfInterest[unitDefID].translatedHumanName then
				message = unitOfInterest[unitDefID].translatedHumanName .. " Spotted"
			end

			AddEvent({ message = message, type = "neutral", icon = iconPath, point = { x = x, z = z } })
		end

		return
	end

	if techlevel < dm_handle.techlevel and not isCommander[unitDefID] and not unitOfInterest[unitDefID] then
		return
	end

	local iconType = unitDef and unitDef.iconType
	local iconName = iconType and icontypes[iconType] and icontypes[iconType].bitmap
	local iconPath = iconName and ("/" .. iconName) or "/icons/empty.png"
	local x, y, z = spGetUnitPosition(unitID)
	local prefix = ""

	if techlevel and techlevel > 1 then
		prefix = " T" .. techlevel
	end

	local message = "Enemy" .. prefix .. " Spotted"
	if unitOfInterest[unitDefID] and unitOfInterest[unitDefID].translatedHumanName then
		message = unitOfInterest[unitDefID].translatedHumanName .. " Spotted"
	end

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
	-- Early exit for non-allied units and small damage
	if unitTeam ~= myTeamID or damage < 10 then
		return
	end

	if CommanderDamaged(unitID, unitDefID, unitTeam, damage, paralyzer) then
		return
	end

	local unitDef = UnitDefs[unitDefID]
	local techlevel = unitDef and unitDef.customParams and tonumber(unitDef.customParams.techlevel) or nil

	if techlevel < dm_handle.techlevel and not unitOfInterest[unitDefID] then
		return
	end

	local iconType = unitDef and unitDef.iconType
	local iconName = iconType and icontypes[iconType] and icontypes[iconType].bitmap
	local iconPath = iconName and ("/" .. iconName) or "/icons/empty.png"
	local x, y, z = spGetUnitPosition(unitID)

	AddEvent({
		message = "Unit under attack",
		type = "bad",
		duration = 10,
		icon = iconPath,
		unitid = unitID,
		point = { x = x, z = z }
	})
end

-- Handle spacebar press when no units are selected
function widget:KeyPress(key, mods, isRepeat, label, unicode)
	if not lastEventAdded then return false end
	-- 32 is the keycode for spacebar
	if key == 32 and spGetSelectedUnitsCount() == 0 then
		local x, y, z = nil, nil, nil
		if lastEventAdded and lastEventAdded.unitid then
			x, y, z = spGetUnitPosition(lastEventAdded.unitid)
		end
		if x and y and z then -- unit is still alive
			spSetCameraTarget(x, y, z)
			spSelectUnit(lastEventAdded.unitid)
			return true
		end
		if lastEventAdded and lastEventAdded.point then
			spSetCameraTarget(lastEventAdded.point.x, 0, lastEventAdded.point.z)
			return true
		end

		-- go to an idle constructor if any
		for unitID, _ in pairs(idleConstructors) do
			x, y, z = spGetUnitPosition(unitID)
			if x and y and z then -- unit is still alive
				spSetCameraTarget(x, y, z)
				spSelectUnit(unitID)
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
		local x, y, z = spGetUnitPosition(unitID)
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
	unitDefIDCache[unitID] = nil

	if newTeam ~= ourTeamID then
		return
	end

	local unitDef = UnitDefs[unitDefID]
	local iconType = unitDef and unitDef.iconType
	local iconName = iconType and icontypes[iconType] and icontypes[iconType].bitmap
	local iconPath = iconName and ("/" .. iconName) or "/icons/empty.png"
	local x, y, z = spGetUnitPosition(unitID)
	AddEvent({
		message = "New unit(s) acquired",
		type = "good",
		icon = iconPath,
		unitid = unitID,
		point = { x = x, z = z }
	})
end

function widget:UnitTaken(unitID, unitDefID, oldTeam, newTeam)
	idleConstructors[unitID] = nil
	unitDefIDCache[unitID] = nil
end
