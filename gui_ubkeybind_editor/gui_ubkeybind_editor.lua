-- ubKeybind Editor — widget entry point.
--
-- User-facing keybind editor built on a processor model that translates
-- between engine binds and user keybinds (core/), an engine-sync state
-- machine that keeps preset + overrides + live state aligned (runtime/), and
-- an RmlUi front end (ui/, .rml/.rcss).
--
-- Truth model: the selected BAR preset (engine config "KeybindingFile",
-- loaded by cmd_bar_hotkeys) is the BASE; this widget persists only per-unit
-- OVERRIDES and applies them on top after every preset load.
--
-- This entry file wires widget callins only; all logic lives in the modules.

if not RmlUi then
	return false
end

local widget = widget ---@type Widget

function widget:GetInfo()
	return {
		name = "ubKeybind Editor",
		desc = "User-friendly keybind editor (preset + overrides)",
		author = "uBdead",
		date = "July 2026",
		license = "GNU GPL, v2 or later",
		layer = 6001, -- we want to be kind of late so other widgets can first register their actions
		enabled = true,
		handler = true,
	}
end

local WIDGET_DIR = "LuaUI/Widgets/gui_ubkeybind_editor/"
local RML_PATH = WIDGET_DIR .. "gui_ubkeybind_editor.rml"
local CATALOG_PATH = WIDGET_DIR .. "keybinds_catalog.json"
local MODEL_NAME = "ubke_model"
local DEFAULT_PRESET = "luaui/configs/hotkeys/grid_keys.txt"
local KEYCODE_ESC = 27

local spEcho = Spring.Echo

local function log(msg)
	spEcho("ubKeybind Editor: " .. tostring(msg))
end

----------------------------------------------------------------------
-- Module loading (depth-3 files are invisible to the widget handler;
-- everything is pulled in explicitly)
----------------------------------------------------------------------

local function rawInclude(path)
	return VFS.Include(path, nil, VFS.RAW_FIRST)
end

local function includeCore(name)
	return rawInclude(WIDGET_DIR .. "core/" .. name)
end

local core = includeCore("init.lua")(includeCore)
local EngineSync = rawInclude(WIDGET_DIR .. "runtime/engine_sync.lua")
local Consumers = rawInclude(WIDGET_DIR .. "runtime/consumers.lua")
local Persistence = rawInclude(WIDGET_DIR .. "runtime/persistence.lua")
local Capture = rawInclude(WIDGET_DIR .. "runtime/capture.lua")
local ViewModel = rawInclude(WIDGET_DIR .. "ui/view_model.lua")

-- Base game JSON library (game archive), same one the rest of BAR uses.
local Json = Json or VFS.Include('common/luaUtilities/json.lua')

----------------------------------------------------------------------
-- State
----------------------------------------------------------------------

local model -- core model facade
local engineSync ---@type EngineSync
local viewModel ---@type ViewModel
local capture -- capture session
local document
local rmlContext
local pendingConfigData
local uiPrefs = {}
local visible = false
local debugMode = false
-- Frame 0 == still in the pregame ready-up/lobby screen (gui_pregameui.lua
-- uses the same GetGameFrame()/GameFrame-callin signal to detect this).
-- The editor must stay hidden until the match actually starts.
local gameStarted = Spring.GetGameFrame() > 0

----------------------------------------------------------------------
-- Layout-aware display of scancodes (reuses BAR's layout tables when
-- available; identity = qwerty otherwise)
----------------------------------------------------------------------

local keyConfig
do
	local ok, cfg = pcall(VFS.Include, "luaui/configs/keyboard_layouts.lua")
	if ok and type(cfg) == "table" then
		keyConfig = cfg
	end
end

local function scToChar(scName)
	if keyConfig and keyConfig.sanitizeKey then
		local layout = Spring.GetConfigString("KeyboardLayout", "qwerty")
		local ok, res = pcall(keyConfig.sanitizeKey, "sc_" .. scName, layout)
		if ok and type(res) == "string" and res ~= "" then
			return res
		end
	end
	return scName
end

----------------------------------------------------------------------
-- UI plumbing
----------------------------------------------------------------------

local function presetShortName()
	local file = Spring.GetConfigString("KeybindingFile", DEFAULT_PRESET)
	return file:match("([^/\\]+)%.txt$") or file
end

local function refreshStatus()
	if not viewModel then
		return
	end
	local parts = { "Base: " .. presetShortName() }
	if model and model.hasBase() then
		parts[#parts + 1] = model.overrideCount() .. " overrides"
	end
	parts[#parts + 1] = engineSync and engineSync.state or "?"
	viewModel:setStatus(table.concat(parts, "  |  "))
end

local function refreshUI()
	if viewModel and model and model.hasBase() then
		viewModel:rebuild(model, uiPrefs)
	end
	refreshStatus()
end

local function setVisible(on)
	if on and not gameStarted then
		-- Still in the pregame lobby: refuse to show regardless of caller
		-- (toggle hotkey, dev-default at Initialize, ...).
		on = false
	end
	visible = on
	if document then
		if on then
			-- The engine can drop SDL text-input mode globally (e.g. after
			-- the chat console closes, gui_chat.lua calls
			-- Spring.SDLStopTextInput() unconditionally) and nothing else
			-- turns it back on for us, so the search box stops accepting
			-- typed characters. Defensively re-enable it whenever we open,
			-- same workaround BAR's own chat widget uses for itself.
			Spring.SDLStartTextInput()
			document:Show()
		else
			-- An active capture session swallows every KeyPress (see
			-- widget:KeyPress) regardless of document visibility — cancel it
			-- so hiding the window (e.g. clicking X mid-capture) can't leave
			-- all keyboard input eaten while invisible.
			if capture and capture:isActive() then
				capture:cancel()
			end
			-- Drop focus before hiding so a still-focused search input
			-- doesn't keep swallowing keys (Tab included) while invisible.
			local input = document:GetElementById("ubke-search")
			if input then
				pcall(function() input:Blur() end)
			end
			document:Hide()
		end
	end
end

----------------------------------------------------------------------
-- Capture + apply
----------------------------------------------------------------------

local function unitLabel(unitId)
	local unit = model and model.getUnit(unitId)
	if not unit then
		return unitId
	end
	local label = unit.entry.label
	if unit.paramLabel then
		label = label .. " " .. unit.paramLabel
	end
	return label
end

-- Turn probe hits into one "Also bound: ..." line.
local function describeHits(hits)
	local names, seen = {}, {}
	for _, h in ipairs(hits) do
		local name = h.unitId and unitLabel(h.unitId) or h.action
		if h.source == "companion" then
			name = name .. " (queue)"
		elseif h.source == "unmanaged" then
			name = name .. " (other)"
		end
		if not seen[name] then
			seen[name] = true
			names[#names + 1] = name
		end
	end
	if #names == 0 then
		return ""
	end
	return "Also bound: " .. table.concat(names, ", ")
end

-- Push the current capture state into the overlay (pending combo + live
-- conflict/validation feedback).
local function onCaptureChange(cap)
	local conflictText = ""
	if cap.message then
		conflictText = cap.message
	else
		local pending = cap:pendingCanonical()
		if pending then
			-- Live validation first (e.g. Shift reserved for auto_shift),
			-- then a conflict preview if the keyset is otherwise legal.
			local ok, reason = model.validateBinding(cap.unitId, pending)
			if not ok then
				conflictText = reason or "invalid keybind"
			else
				local hits = model.probeConflicts(cap.unitId, pending)
				if hits and #hits > 0 then
					conflictText = describeHits(hits)
				end
			end
		end
	end
	viewModel:setCapture({
		active = true,
		actionLabel = cap.actionLabel,
		pendingDisplay = cap:pendingDisplay(scToChar),
		hasConflicts = conflictText ~= "",
		conflictText = conflictText,
	})
end

-- Build the new full keyset list for a slot edit and apply it.
local function onCaptureCommit(unitId, slot, keysetStr)
	local current = model.effectiveKeysets(unitId) or {}
	local newList = {}
	for i, ks in ipairs(current) do
		newList[i] = ks
	end
	if keysetStr == nil then
		if slot <= #newList then
			table.remove(newList, slot)
		end
	else
		newList[slot] = keysetStr
	end

	local plan, err = model.setBinding(unitId, newList)
	if not plan then
		-- Reopen the overlay with the validation reason so the user can retry.
		capture:begin({ unitId = unitId, slot = slot, actionLabel = unitLabel(unitId) })
		capture:setMessage(err or "invalid keybind")
		return
	end

	-- widgetHandler:DisownText()
	widgetHandler.textOwner = nil
	viewModel:setCapture({ active = false })
	local ok, execErr = engineSync:execute(plan)
	if not ok then
		log("apply failed: " .. tostring(execErr))
	end
	refreshUI()
end

local function onCaptureCancel()
	-- widgetHandler:DisownText()
	widgetHandler.textOwner = nil
	viewModel:setCapture({ active = false })
end

-- Drop one unit's override, restoring its preset-default binding.
local function onResetUnit(unitId)
	if not engineSync:canEdit() then
		return
	end
	local plan, err = model.resetUnit(unitId)
	if not plan then
		log("revert failed: " .. tostring(err))
		return
	end
	local ok, execErr = engineSync:execute(plan)
	if not ok then
		log("apply failed: " .. tostring(execErr))
	end
	refreshUI()
end

-- A binding slot ("<slot>:<unitId>") or per-row reset ("reset:<unitId>")
-- was clicked.
local function onRowEvent(token)
	local resetUnitId = token:match("^reset:(.+)$")
	if resetUnitId then
		onResetUnit(resetUnitId)
		return
	end

	local slotStr, unitId = token:match("^(%d+):(.+)$")
	if not unitId then
		return
	end
	local unit = model.getUnit(unitId)
	if not unit or unit.locked then
		return
	end
	if not engineSync:canEdit() then
		return
	end
	-- Focused inputs (search box) would swallow key events; drop focus.
	if document then
		local input = document:GetElementById("ubke-search")
		if input then
			pcall(function() input:Blur() end)
		end
	end
	-- Take modal text ownership so our KeyPress runs before the LuaUI action
	-- handler and consumes every key while capturing.
	-- widgetHandler:OwnText()
	widgetHandler.textOwner = self
	capture:begin({
		unitId = unitId,
		slot = tonumber(slotStr),
		actionLabel = unitLabel(unitId),
	})
end

----------------------------------------------------------------------
-- Functions called from RML (inline handlers)
----------------------------------------------------------------------

function widget:Close()
	setVisible(false)
end

function widget:Reload()
	widget:Shutdown()
	widget:Initialize()
end

function widget:ToggleDebugger()
	if debugMode then
		RmlUi.SetDebugContext(nil)
	else
		RmlUi.SetDebugContext("shared")
	end
	debugMode = not debugMode
	if viewModel then
		viewModel:setDebug(debugMode)
	end
end

function widget:Resync()
	if engineSync then
		engineSync:requestPristineResync("manual")
	end
	refreshStatus()
end

function widget:RevertAll()
	if not model or not engineSync or not engineSync:canEdit() then
		return
	end
	local plan = model.resetAll()
	local ok, execErr = engineSync:execute(plan)
	if not ok then
		log("apply failed: " .. tostring(execErr))
	end
	refreshUI()
end

function widget:CaptureAccept()
	if capture then
		capture:accept()
	end
end

function widget:CaptureUnbind()
	if capture then
		capture:unbind()
	end
end

function widget:CaptureCancel()
	if capture then
		capture:cancel()
	end
end

function widget:OnSearchFocus()
	-- Same SDL-text-input-mode workaround as setVisible(true) — clicking
	-- into the box is the moment typing is actually about to happen.
	Spring.SDLStartTextInput()
end

function widget:OnSearchChanged(event)
	if not viewModel then
		return
	end
	local value
	if event and event.parameters then
		value = event.parameters.value
	end
	if value == nil and event and event.current_element then
		local ok, attr = pcall(function()
			return event.current_element:GetAttribute("value")
		end)
		if ok then
			value = attr
		end
	end
	viewModel:setSearch(value or "")
end

----------------------------------------------------------------------
-- Custom widget action discovery
----------------------------------------------------------------------

-- True for widgets shipped inside the game archive (the standard, bundled
-- widget set) as opposed to loose/user-installed ones. Bundled widgets'
-- actions aren't "custom" even though they go through the same AddAction
-- path — they just haven't been added to keybinds_catalog.json yet.
local function isBundledWidget(w)
	local name = w and w.whInfo and w.whInfo.name
	local known = name and widgetHandler.knownWidgets and widgetHandler.knownWidgets[name]
	return known ~= nil and known.fromZip == true
end

-- Every action a currently-loaded, non-bundled (user-installed) widget
-- registered for key binding via widgetHandler:AddAction(cmd, func, data,
-- "p"...). Returns action (string) -> widgetNames (string[]); core/catalog.lua
-- merges this into a synthetic "Custom Widget Actions" category so these
-- become normal, bindable units.
local function discoverWidgetActions()
	local ah = widgetHandler and widgetHandler.actionHandler
	if not ah or type(ah.keyPressActions) ~= "table" then
		return nil
	end
	local out = {}
	for cmd, callInfoList in pairs(ah.keyPressActions) do
		local names, seen = {}, {}
		for _, callInfo in ipairs(callInfoList) do
			local w = callInfo[1]
			if not isBundledWidget(w) then
				local name = (w and w.whInfo and w.whInfo.name) or "?"
				if not seen[name] then
					seen[name] = true
					names[#names + 1] = name
				end
			end
		end
		if #names > 0 then
			out[cmd] = names
		end
	end
	return out
end

----------------------------------------------------------------------
-- Widget lifecycle
----------------------------------------------------------------------

function widget:Initialize()
	-- Catalog
	local catalogText = VFS.LoadFile(CATALOG_PATH, VFS.RAW_FIRST)
	if not catalogText then
		log("failed to read " .. CATALOG_PATH)
		widgetHandler:RemoveWidget(widget)
		return
	end
	local okDecode, decoded = pcall(Json.decode, catalogText)
	if not okDecode or type(decoded) ~= "table" then
		log("failed to parse " .. CATALOG_PATH .. ": " .. tostring(decoded))
		widgetHandler:RemoveWidget(widget)
		return
	end

	-- Core model (+ persisted overrides, stashed by SetConfigData pre-init)
	local overridesData
	overridesData, uiPrefs = Persistence.load(pendingConfigData)
	local errs
	model, errs = core.model.new({
		catalogTable = decoded,
		presetKey = Spring.GetConfigString("KeybindingFile", DEFAULT_PRESET),
		persistedOverrides = overridesData,
		widgetActions = discoverWidgetActions(),
	})
	if not model then
		for _, e in ipairs(errs or {}) do
			log("catalog error: " .. e)
		end
		widgetHandler:RemoveWidget(widget)
		return
	end
	for _, e in ipairs(model.catalogErrors or {}) do
		log("catalog warning: " .. e)
	end
	for _, ref in ipairs(model.sanitizedOverrides or {}) do
		log("dropped a corrupted saved keybind override (" .. ref .. ") — it never reached the engine, reverted to preset default")
	end

	-- RmlUi
	rmlContext = RmlUi.GetContext("shared")
	if not rmlContext then
		log("no shared RML context")
		widgetHandler:RemoveWidget(widget)
		return
	end
	viewModel = ViewModel.new({
		core = core,
		rmlContext = rmlContext,
		modelName = MODEL_NAME,
		scToChar = scToChar,
		onEvent = onRowEvent,
	})
	document = rmlContext:LoadDocument(RML_PATH, widget)
	if not document then
		log("failed to load " .. RML_PATH)
		widget:Shutdown()
		widgetHandler:RemoveWidget(widget)
		return
	end
	document:ReloadStyleSheet()
	setVisible(true) -- dev default; release will start hidden behind /ubkeybinds

	-- Key capture session
	capture = Capture.new({
		keyset = core.keyset,
		getKeySymbol = Spring.GetKeySymbol,
		getScanSymbol = Spring.GetScanSymbol,
		getMeta = function()
			local _, _, meta = Spring.GetModKeyState()
			return meta
		end,
		onChange = onCaptureChange,
		onCommit = onCaptureCommit,
		onCancel = onCaptureCancel,
	})

	-- Engine sync
	engineSync = EngineSync.new({
		model = model,
		keyset = core.keyset,
		consumers = Consumers,
		onSynced = refreshUI,
		onStateChanged = refreshStatus,
		log = log,
	})
	engineSync:initialize()

	widgetHandler.actionHandler:AddAction(self, "ubkeybinds", function()
		Spring.Echo("ubKeybind Editor: toggle visibility")
		setVisible(not visible)
		return true
	end, nil, "tp")

	refreshStatus()
end

function widget:GameFrame(_gf)
	-- Only fires once the match is actually running (never called during the
	-- frame-0 pregame lobby), so this is a one-way lobby -> in-game flip.
	gameStarted = true
end

function widget:Update(dt)
	if engineSync then
		engineSync:update(dt)
	end
	if viewModel then
		viewModel:update(dt)
	end
	if capture then
		capture:update(dt)
	end
end

function widget:KeyPress(key, mods, isRepeat, label, unicode, scanCode, actions)
	if capture and capture:isActive() then
		if key == KEYCODE_ESC then
			capture:cancel()
		else
			capture:keyPress(key, mods, isRepeat, scanCode)
		end
		return true -- swallow all input while capturing
	end
	if visible and key == KEYCODE_ESC then
		setVisible(false)
		return true
	end
	return false
end

function widget:KeyRelease(key, mods, label, unicode, scanCode)
	if capture and capture:isActive() then
		capture:keyRelease(key, mods, scanCode)
		return true
	end
	return false
end

function widget:GetConfigData()
	if not model then
		-- Init failed or never ran: keep whatever was stored before rather
		-- than wiping the user's overrides.
		return pendingConfigData
	end
	if viewModel then
		uiPrefs = viewModel:uiPrefs()
	end
	return Persistence.dump(model, uiPrefs)
end

function widget:SetConfigData(data)
	pendingConfigData = data
end

function widget:Shutdown()
	-- pcall(function() widgetHandler:DisownText() end)
	widgetHandler.textOwner = nil
	capture = nil
	if engineSync then
		engineSync:shutdown()
		engineSync = nil
	end
	if viewModel then
		viewModel:close()
		viewModel = nil
	end
	if document then
		document:Close()
		document = nil
	end
	rmlContext = nil
end
