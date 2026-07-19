-- ubKeybind Editor — RmlUi view model.
--
-- Owns the ONE authoritative Lua table behind the RmlUi data model. RmlUi's
-- Lua binding reliably dirties top-level fields only, so the pattern
-- (prototype-proven) is: mutate our table, then reassign the top-level field
-- on the handle (`touch`).
--
-- Search filters via visibility flags — rows are never re-created per
-- keystroke, so RmlUi only re-evaluates data-class bindings instead of
-- rebuilding ~400 rows of DOM. Structural refreshes (bindings changed,
-- resync) rebuild the category tree; they are rare.

---@class ViewModel
---@field core table
---@field scToChar fun(scName: string): string|nil
---@field modelName string
---@field rmlContext table|nil
---@field model table
---@field handle table|nil
---@field query string
---@field searchPending string|nil
---@field searchTimer number
local ViewModel = {}
ViewModel.__index = ViewModel

---@param deps table { core, rmlContext, modelName, scToChar, onEvent }
function ViewModel.new(deps)
	local self = setmetatable({}, ViewModel)
	self.core = deps.core
	self.scToChar = deps.scToChar
	self.modelName = deps.modelName
	self.rmlContext = deps.rmlContext
	self.onEvent = deps.onEvent or function() end

	self.model = {
		ui = {
			statusLine = "Waiting for engine...",
			debug = false,
			levelFilter = "common",
		},
		view = {
			categories = {},
		},
		capture = {
			active = false,
			actionLabel = "",
			pendingDisplay = "",
			hasConflicts = false,
			conflictText = "",
		},
		-- Row click tokens ("slot:unitId") are written here by data-event-click
		-- and drained in :update(). RmlUi two-way binding writes back to this
		-- table (same mechanism as category.collapsed).
		event = "",
		-- Level filter button clicks ("common"/"uncommon"/"advanced"/"all"),
		-- same drain-on-update pattern as `event`.
		filterClick = "",
	}

	self.query = ""
	self.searchPending = nil
	self.searchTimer = 0
	self.prefsSeeded = false

	self.handle = self.rmlContext:OpenDataModel(self.modelName, self.model)
	return self
end

function ViewModel:touch(field)
	if self.handle then
		self.handle[field] = self.model[field]
	end
end

---Rebuild the category tree from core state. `uiPrefs.collapsed` preserves
---collapse state across rebuilds and sessions.
function ViewModel:rebuild(coreModel, uiPrefs)
	local K = self.core.keyset
	local collapsedPref = (uiPrefs and uiPrefs.collapsed) or {}

	-- Seed the persisted level filter once at startup; later resyncs must not
	-- clobber a live in-session change back to the startup value.
	if not self.prefsSeeded then
		self.prefsSeeded = true
		self.model.ui.levelFilter = (uiPrefs and uiPrefs.levelFilter) or "common"
	end

	-- Conflict badge lookup from the managed scan.
	local conflicted = {}
	for _, c in ipairs(coreModel.allConflicts()) do
		conflicted[c.a.unitId] = true
		conflicted[c.b.unitId] = true
	end

	local categories = {}
	local byName = {}
	for i, c in ipairs(coreModel.listCategories()) do
		local category = {
			name = c.name,
			label = c.label,
			index = i,
			collapsed = collapsedPref[c.name] or false,
			visible = true,
			matchCount = 0,
			rows = {},
		}
		categories[#categories + 1] = category
		byName[c.name] = category
	end

	for _, row in ipairs(coreModel.listUnits()) do
		local category = byName[row.category]
		if category and not row.hidden then
			local primary = { slot = 1, display = "Unbound", bound = false }
			local secondary = { slot = 2, display = "Unbound", bound = false }
			local chipText = {}
			for slot, ks in ipairs(row.keysets) do
				local display = K.display(ks, self.scToChar)
				chipText[#chipText + 1] = display
				if slot == 1 then
					primary = { slot = 1, display = display, bound = true }
				elseif slot == 2 then
					secondary = { slot = 2, display = display, bound = true }
				end
			end

			local label = row.label
			if row.paramLabel then
				label = label .. " " .. row.paramLabel
			end

			category.rows[#category.rows + 1] = {
				uid = row.unitId,
				label = label,
				tooltip = row.tooltip or "",
				locked = row.locked or false,
				level = row.level or "common",
				overridden = row.overridden or false,
				conflicted = conflicted[row.unitId] or false,
				hasDrift = row.drift ~= nil and #row.drift > 0,
				visible = true,
				primary = primary,
				secondary = secondary,
				-- Click tokens consumed by :update(): "<slot>:<unitId>".
				primaryEvent = "1:" .. row.unitId,
				secondaryEvent = "2:" .. row.unitId,
				searchText = (label .. " " .. row.action .. " " .. table.concat(chipText, " ")):lower(),
			}
		end
	end

	self.model.view.categories = categories
	self:applySearch()
end

----------------------------------------------------------------------
-- Search (debounced by :update)
----------------------------------------------------------------------

function ViewModel:setSearch(query)
	self.searchPending = tostring(query or "")
	self.searchTimer = 0.15
end

function ViewModel:update(dt)
	if self.searchPending then
		self.searchTimer = self.searchTimer - dt
		if self.searchTimer <= 0 then
			self.query = self.searchPending:lower():gsub("^%s+", ""):gsub("%s+$", "")
			self.searchPending = nil
			self:applySearch()
		end
	end

	-- Drain a row click written by data-event-click.
	local ev = self.model.event
	if ev and ev ~= "" then
		self.model.event = ""
		self:touch("event")
		self.onEvent(ev)
	end

	-- Drain a level-filter button click.
	local fc = self.model.filterClick
	if fc and fc ~= "" then
		self.model.filterClick = ""
		self:touch("filterClick")
		self:setLevelFilter(fc)
	end
end

---Switch the cumulative visibility tier ("common"/"uncommon"/"advanced"/"all")
---and re-apply filtering. A no-op if already on that tier.
function ViewModel:setLevelFilter(level)
	if self.model.ui.levelFilter == level then
		return
	end
	self.model.ui.levelFilter = level
	self:touch("ui")
	self:applySearch()
end

function ViewModel:applySearch()
	local query = self.query
	local maxRank = self.core.catalog.levelRank(self.model.ui.levelFilter)
	for _, category in ipairs(self.model.view.categories) do
		local matches = 0
		for _, row in ipairs(category.rows) do
			local textOk = query == "" or row.searchText:find(query, 1, true) ~= nil
			local levelOk = self.core.catalog.levelRank(row.level) <= maxRank
			row.visible = textOk and levelOk
			if row.visible then
				matches = matches + 1
			end
		end
		category.matchCount = matches
		category.visible = matches > 0
	end
	self:touch("view")
end

----------------------------------------------------------------------
-- Status / capture / prefs
----------------------------------------------------------------------

function ViewModel:setStatus(line)
	self.model.ui.statusLine = line
	self:touch("ui")
end

function ViewModel:setDebug(on)
	self.model.ui.debug = on
	self:touch("ui")
end

function ViewModel:setCapture(state)
	local c = self.model.capture
	c.active = state.active or false
	c.actionLabel = state.actionLabel or ""
	c.pendingDisplay = state.pendingDisplay or ""
	c.hasConflicts = state.hasConflicts or false
	c.conflictText = state.conflictText or ""
	self:touch("capture")
end

---True if a row click is queued (widget suppresses window-close on the same
---click that opened capture, etc. — currently informational).
function ViewModel:hasPendingEvent()
	return self.model.event ~= nil and self.model.event ~= ""
end

---Collapse flags for persistence (RmlUi data expressions write back into our
---table, so the current values live in model.view).
function ViewModel:uiPrefs()
	local collapsed = {}
	for _, category in ipairs(self.model.view.categories) do
		if category.collapsed then
			collapsed[category.name] = true
		end
	end
	return { collapsed = collapsed, levelFilter = self.model.ui.levelFilter }
end

function ViewModel:close()
	if self.handle and self.rmlContext then
		self.rmlContext:RemoveDataModel(self.modelName)
	end
	self.handle = nil
	self.rmlContext = nil
end

return ViewModel
