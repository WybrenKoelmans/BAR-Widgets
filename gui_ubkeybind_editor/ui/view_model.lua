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
			unboundOnly = false,
			-- Mirrors "every category is collapsed" so the collapse-all button
			-- can flip its label; kept in sync by :update() polling (individual
			-- category headers write `collapsed` straight back into our table).
			allCollapsed = false,
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
		-- "Unbound only" toggle click, same drain-on-update pattern as `event`.
		unboundToggle = false,
		-- Collapse/expand-all button click, same drain-on-update pattern.
		collapseToggle = false,
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
		self.model.ui.unboundOnly = (uiPrefs and uiPrefs.unboundOnly) or false
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
				-- Click tokens consumed by :update(): "<slot>:<unitId>", or
				-- "reset:<unitId>" for the per-row revert-to-default control.
				primaryEvent = "1:" .. row.unitId,
				secondaryEvent = "2:" .. row.unitId,
				resetEvent = "reset:" .. row.unitId,
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

	-- Drain an "unbound only" toggle click.
	if self.model.unboundToggle then
		self.model.unboundToggle = false
		self:touch("unboundToggle")
		self:setUnboundOnly(not self.model.ui.unboundOnly)
	end

	-- Drain a collapse/expand-all click.
	if self.model.collapseToggle then
		self.model.collapseToggle = false
		self:touch("collapseToggle")
		self:setAllCollapsed(not self:allCollapsed())
	end

	-- Individual category headers flip `collapsed` directly in our table via
	-- two-way binding (no callback), so the button label is synced by polling.
	local all = self:allCollapsed()
	if self.model.ui.allCollapsed ~= all then
		self.model.ui.allCollapsed = all
		self:touch("ui")
	end
end

---True when every category is collapsed (false with no categories, so the
---button reads "Collapse all" until content exists).
function ViewModel:allCollapsed()
	local categories = self.model.view.categories
	if #categories == 0 then
		return false
	end
	for _, category in ipairs(categories) do
		if not category.collapsed then
			return false
		end
	end
	return true
end

function ViewModel:setAllCollapsed(on)
	for _, category in ipairs(self.model.view.categories) do
		category.collapsed = on
	end
	self:touch("view")
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

---Toggle showing only actions with neither a primary nor a secondary bind.
---Turning it on also jumps the level filter to "all" — an unbound advanced
---or uncommon action would otherwise stay hidden by the current tier.
function ViewModel:setUnboundOnly(on)
	if self.model.ui.unboundOnly == on then
		return
	end
	self.model.ui.unboundOnly = on
	if on then
		self.model.ui.levelFilter = "all"
	end
	self:touch("ui")
	self:applySearch()
end

function ViewModel:applySearch()
	local query = self.query
	local searching = query ~= ""
	local maxRank = self.core.catalog.levelRank(self.model.ui.levelFilter)
	local unboundOnly = self.model.ui.unboundOnly
	for _, category in ipairs(self.model.view.categories) do
		local matches = 0
		for _, row in ipairs(category.rows) do
			local textOk = not searching or row.searchText:find(query, 1, true) ~= nil
			-- A search should surface matches from every level tier, not just
			-- the currently selected one.
			local levelOk = searching or self.core.catalog.levelRank(row.level) <= maxRank
			local unboundOk = not unboundOnly or (not row.primary.bound and not row.secondary.bound)
			row.visible = textOk and levelOk and unboundOk
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
	return { collapsed = collapsed, levelFilter = self.model.ui.levelFilter, unboundOnly = self.model.ui.unboundOnly }
end

function ViewModel:close()
	if self.handle and self.rmlContext then
		self.rmlContext:RemoveDataModel(self.modelName)
	end
	self.handle = nil
	self.rmlContext = nil
end

return ViewModel
