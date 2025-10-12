if not RmlUi then
	return false
end

local widget = widget ---@type Widget

-- Load icontypes table from BAR.sdd/gamedata/icontypes.lua
local icontypes = VFS.Include("gamedata/icontypes.lua")

function widget:GetInfo()
	return {
		name = "Battle Log",
		desc = "Displays important battle events in a log",
		author = "uBdead",
		date = "2025",
		license = "GNU GPL, v2 or later",
		layer = 1,
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

local fontSize = 16                 -- default font size
local maxEvents = 25                -- default maximum number of events
local durationMultiplier = 1.0      -- default duration multiplier
local groupingDistance = 2000       -- default grouping distance
local sqrGroupingDistance = 4000000 -- default grouping distance (2000^2)
local repeatWarnings = true         -- default: do not repeat warnings of same type
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
	fontsize = fontSize,
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
	-- Apply duration multiplier
	event.duration = event.duration * durationMultiplier

	-- Reverted optimization: check all events for deduplication
	for i = 1, #init_model.events do
		local existing_event = init_model.events[i]
		if existing_event.message == event.message then
			if repeatWarnings then
				lastEventAdded = event
			end
			local withinDistance = true
			if existing_event.point and event.point then
				local dx = existing_event.point.x - event.point.x
				local dz = existing_event.point.z - event.point.z
				-- Use squared distance to avoid sqrt calculation
				local dist2 = dx * dx + dz * dz
				withinDistance = dist2 < sqrGroupingDistance
			end

			if withinDistance then
				-- Update existing event
				existing_event.multiplier = (existing_event.multiplier or 1) + 1
				if repeatWarnings then
					existing_event.frame = event.frame
				end
				if event.point then
					existing_event.point = event.point
				end
				if event.unitid then
					existing_event.unitid = event.unitid
				end
				if event.icon then
					existing_event.icon = event.icon
				end
				-- Update duration if the new event has a longer duration
				if event.duration and (not existing_event.duration or event.duration > existing_event.duration) then
					existing_event.duration = event.duration
				end
				dm_handle.events = init_model.events
				return
			end
		end
	end

	lastEventAdded = event
	table.insert(init_model.events, 1, event)
	if #init_model.events > maxEvents then
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
	Spring.Echo(WIDGET_NAME ..
		": Identified " .. tostring(table.maxn(constructorDefIDs)) .. " constructor unit definitions.")

	-- Register font size, max events, duration multiplier, grouping distance, and repeat warnings options with WG.options if available
	if WG.options and WG.options.addOption then
		WG.options.addOption({
			widgetname = widget:GetInfo().name,
			id = "eventlog_font_size",
			group = "custom",
			category = 2,
			name = "Font Size",
			type = "slider",
			min = 10,
			max = 30,
			step = 1,
			value = fontSize,
			description = "Adjust the font size for the BattleLog event list.",
			onchange = function(_, value)
				Spring.Echo(WIDGET_NAME .. ": Font size changed to " .. tostring(value))
				fontSize = tonumber(value)
				if dm_handle then
					dm_handle.fontsize = fontSize
				end
				if document and document.ReloadStyleSheet then
					document:ReloadStyleSheet()
				end
			end
		})
		WG.options.addOption({
			widgetname = widget:GetInfo().name,
			id = "eventlog_max_events",
			group = "custom",
			category = 2,
			name = "Maximum Events",
			type = "slider",
			min = 5,
			max = 100,
			step = 1,
			value = maxEvents,
			description = "Set the maximum number of events to display in the BattleLog.",
			onchange = function(_, value)
				Spring.Echo(WIDGET_NAME .. ": Max events changed to " .. tostring(value))
				maxEvents = tonumber(value)
				if dm_handle then
					-- Optionally, update the model if you want to expose maxEvents to RML
				end
				-- Trim the event list if needed
				while #init_model.events > maxEvents do
					table.remove(init_model.events)
				end
				if dm_handle then
					dm_handle.events = init_model.events
				end
			end
		})
		WG.options.addOption({
			widgetname = widget:GetInfo().name,
			id = "eventlog_duration_multiplier",
			group = "custom",
			category = 2,
			name = "Duration Multiplier",
			type = "slider",
			min = 0.1,
			max = 5.0,
			step = 0.1,
			value = durationMultiplier,
			description = "Multiply the duration of all BattleLog events (e.g. 0.5 = half as long, 2.0 = twice as long).",
			onchange = function(_, value)
				Spring.Echo(WIDGET_NAME .. ": Duration multiplier changed to " .. tostring(value))
				durationMultiplier = tonumber(value)
			end
		})
		WG.options.addOption({
			widgetname = widget:GetInfo().name,
			id = "eventlog_grouping_distance",
			group = "custom",
			category = 2,
			name = "Grouping Distance",
			type = "slider",
			min = 100,
			max = 5000,
			step = 50,
			value = groupingDistance,
			description =
			"Distance (in game units) for grouping similar events (default: 2000). Lower = stricter grouping.",
			onchange = function(_, value)
				Spring.Echo(WIDGET_NAME .. ": Grouping distance changed to " .. tostring(value))
				groupingDistance = tonumber(value)
				sqrGroupingDistance = tonumber(value) * tonumber(value)
			end
		})
		WG.options.addOption({
			widgetname = widget:GetInfo().name,
			id = "eventlog_repeat_warnings",
			group = "custom",
			category = 2,
			name = "Repeat Warnings",
			type = "bool",
			value = repeatWarnings,
			description = "If enabled, the same type of event will warn again even if it already exists in the log.",
			onchange = function(_, value)
				Spring.Echo(WIDGET_NAME .. ": Repeat warnings set to " .. tostring(value))
				repeatWarnings = value and true or false
			end
		})
	end

	-- Get the shared RML context
	widget.rmlContext = RmlUi.GetContext("shared")
	if not widget.rmlContext then
		spEcho(WIDGET_NAME .. ": ERROR - Failed to get RML context")
		return false
	end

	-- Create and bind the data model
	init_model.fontsize = fontSize
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

	document:AddEventListener("dragend", function() widget:SavePosition() end)

	-- Apply styles and show the document
	document:ReloadStyleSheet()
	document:Show()
	widget:LoadPosition()
	spEcho(WIDGET_NAME .. ": Widget initialized successfully")

	spEcho(WIDGET_NAME .. ": Font size should be " .. tostring(fontSize) .. "dp now." .. " initial model fontsize: " .. tostring(init_model.fontsize) .. " dm_handle fontsize: " .. tostring(dm_handle.fontsize))
	-- RmlUi.SetDebugContext('shared')

	return true
end

local function AddIdleConstructorEvent(unitID, unitDefID)
	local unitDef = UnitDefs[unitDefID]
	local iconType = unitDef and unitDef.iconType
	local iconName = iconType and icontypes[iconType] and icontypes[iconType].bitmap
	local iconPath = iconName and ("/" .. iconName) or "/icons/empty.png"
	local x, y, z = spGetUnitPosition(unitID)
	local techlevel = unitDef and unitDef.customParams and tonumber(unitDef.customParams.techlevel) or nil
	if techlevel and techlevel < dm_handle.techlevel then
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
end

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
					if not idleConstructors[unitID] then
						AddIdleConstructorEvent(unitID, unitDefID)
					end
					idleConstructors[unitID] = true
				else
					idleConstructors[unitID] = nil
				end
			end
		end
	end
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
	-- if dm_handle then
	-- 	dm_handle.debugMode = not dm_handle.debugMode

	-- 	if dm_handle.debugMode then
	-- 		RmlUi.SetDebugContext('shared')
	-- 		spEcho(WIDGET_NAME .. ": RmlUi debugger enabled")
	-- 	else
	-- 		RmlUi.SetDebugContext(nil)
	-- 		spEcho(WIDGET_NAME .. ": RmlUi debugger disabled")
	-- 	end
	-- end
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
		lastRemovalCheckFrame = frame
		local currentTime = spGetGameFrame()
		local i = 1
		while i <= #init_model.events do
			local event = init_model.events[i]
			if event.frame and event.duration then
				local ageInFrames = currentTime - event.frame
				if ageInFrames > (event.duration * 30) then -- duration is already multiplied
					table.remove(init_model.events, i)
				else
					i = i + 1
				end
			else
				i = i + 1
			end
		end
		dm_handle.events = init_model.events
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

function widget:UnitDestroyed(unitID, unitDefID, unitTeam, attackerID, attackerDefID, attackerTeam, weaponDefID)
	if weaponDefID == -10 then return end -- ignore self-destructions
	if weaponDefID == -12 then return end -- ignore reclaimed
	if weaponDefID == -15 then return end -- ignore still under factory construction
	if weaponDefID == -16 then return end -- ignore factory cancellation
	if weaponDefID == -19 then return end -- ignore decayed

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
			AddEvent({ message = message, type = "bad", icon = iconPath, point = { x = x, z = z } })
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

			AddEvent({ message = message, type = "terrible", icon = iconPath, point = { x = x, z = z } })
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

function widget:SavePosition()
	if not document then return end
	local element = document:GetElementById("gui_event_log-widget")
	if not element then return end
	local x = element.offset_left
	local y = element.offset_top
	if not x or not y then return end

	local vsx, vsy = Spring.GetViewGeometry()
	if not vsx or not vsy then return end
	local relX = x / vsx
	local relY = y / vsy
	Spring.SetConfigInt("EventLog_RelativeX", math.floor(relX * 1000)) -- store as int to avoid precision issues
	Spring.SetConfigInt("EventLog_RelativeY", math.floor(relY * 1000))
end

function widget:LoadPosition()
	if not document then return end
	local element = document:GetElementById("gui_event_log-widget")
	if not element then return end
	local relX = Spring.GetConfigInt("EventLog_RelativeX", -1)
	local relY = Spring.GetConfigInt("EventLog_RelativeY", -1)
	if relX == -1 or relY == -1 then return end
	relX = relX / 1000
	relY = relY / 1000
	local vsx, vsy = Spring.GetViewGeometry()
	if not vsx or not vsy then return end
	local x = math.floor(relX * vsx)
	local y = math.floor(relY * vsy)
	element.style.position = "absolute"
	element.style.left = x .. "px"
	element.style.top = y .. "px"
end

-- Save widget state for persistence
function widget:GetConfigData()
	Spring.Echo(WIDGET_NAME .. ": Saving configuration data")
	
	return {
		fontSize = fontSize,
		maxEvents = maxEvents,
		durationMultiplier = durationMultiplier,
		groupingDistance = groupingDistance,
		repeatWarnings = repeatWarnings,
	}
end

-- Restore widget state from persistence
function widget:SetConfigData(data)
	Spring.Echo(WIDGET_NAME .. ": Restoring configuration data")
	if type(data) == "table" then
		if data.fontSize ~= nil then fontSize = data.fontSize end
		if data.maxEvents ~= nil then maxEvents = data.maxEvents end
		if data.durationMultiplier ~= nil then durationMultiplier = data.durationMultiplier end
		if data.groupingDistance ~= nil then
			groupingDistance = data.groupingDistance
			sqrGroupingDistance = groupingDistance * groupingDistance
		end
		if data.repeatWarnings ~= nil then repeatWarnings = data.repeatWarnings end
	end
end
