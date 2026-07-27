-- ubKeybind Editor — model facade.
--
-- The only core API the runtime/UI layers touch. Owns the wiring between
-- catalog, import, overrides, compiler and conflicts, plus the two pieces of
-- session state the compiler needs:
--
--   currentByUnit  what is live in the engine for each unit right now
--                  (base pairs after a refresh, plan.touched after applies)
--   expectedLive   full projected engine state, for the runtime watchdog
--
-- All engine I/O is the caller's job: it feeds snapshots in (plain
-- { command, extra, boundWith } tables) and executes the returned command
-- batches. The model never talks to Spring.

return function(core)
	local catalog = core.catalog
	local import = core.import
	local overrides = core.overrides
	local compile = core.compile
	local conflicts = core.conflicts
	local processors = core.processors
	local keyset = core.keyset

	local M = {}

	---@param deps table { catalogTable, presetKey, persistedOverrides, widgetActions }
	---widgetActions: action (string) -> widgetNames (string[]), from
	---widgetHandler.actionHandler.keyPressActions -- actions installed
	---widgets registered themselves, merged in as an extra catalog category.
	---Returns instance or nil, errors[].
	function M.new(deps)
		local cat, catErrs = catalog.load(deps.catalogTable)
		if not cat then
			return nil, catErrs
		end
		catalog.mergeWidgetActions(cat, deps.widgetActions)

		local store, sanitizedOverrides = overrides.new(deps.persistedOverrides, deps.presetKey)

		local self = {
			catalogErrors = catErrs,
			sanitizedOverrides = sanitizedOverrides, -- ["preset/unitId"]: corrupt persisted keyset, reset to base
		}

		local base = nil ---@type table|nil  ImportResult
		local currentByUnit = {}
		local expectedLive = {}

		---@return table
		local function requireBase()
			if not base then
				error("model used before refreshFromSnapshot")
			end
			return base
		end

		local function planNow()
			return compile.plan(requireBase(), store, currentByUnit, expectedLive)
		end

		----------------------------------------------------------------
		-- Lifecycle
		----------------------------------------------------------------

		---Switch the override namespace (engine KeybindingFile string).
		---Follow with a refreshFromSnapshot once the new preset is live.
		function self.setPreset(presetKey)
			overrides.setPreset(store, presetKey)
		end

		---Adopt a fresh engine snapshot as the pristine BASE, then compute
		---the plan that applies this preset's overrides on top of it.
		---Returns plan, warnings[].
		function self.refreshFromSnapshot(rawBinds)
			local b = import.run(rawBinds, cat)
			base = b
			currentByUnit = {}
			for unitId, unit in pairs(b.units) do
				currentByUnit[unitId] = unit.pairs
			end
			expectedLive = b.livePairs
			return planNow(), b.warnings
		end

		---Record that a plan's command batch landed in the engine.
		function self.commitPlan(plan)
			requireBase()
			for unitId, desired in pairs(plan.touched) do
				currentByUnit[unitId] = desired
			end
			expectedLive = compile.applyExpected(expectedLive, plan)
		end

		function self.hasBase()
			return base ~= nil
		end

		----------------------------------------------------------------
		-- Editing
		----------------------------------------------------------------

		---Replace a unit's bindings (full slot list, keyset strings).
		---Returns plan or nil, err. Caller executes plan.commands, verifies,
		---then calls commitPlan.
		function self.setBinding(unitId, keysetStrings)
			local unit = requireBase().units[unitId]
			if not unit then
				return nil, "unknown keybind '" .. tostring(unitId) .. "'"
			end
			local proc = processors.get(unit.entry.processor.type)
			local ok, err = overrides.set(store, unit, proc, keysetStrings)
			if not ok then
				return nil, err
			end
			return planNow()
		end

		---Drop a unit's override; the plan restores its base binds.
		function self.resetUnit(unitId)
			if not requireBase().units[unitId] then
				return nil, "unknown keybind '" .. tostring(unitId) .. "'"
			end
			overrides.clear(store, unitId)
			return planNow()
		end

		---Drop every override for the current preset.
		function self.resetAll()
			requireBase()
			overrides.clearAll(store)
			return planNow()
		end

		----------------------------------------------------------------
		-- Views
		----------------------------------------------------------------

		function self.getUnit(unitId)
			return requireBase().units[unitId]
		end

		---Effective user-level keysets for a unit as canonical strings, in
		---display order (base, or the override if present). Used by the UI to
		---build the new full list when one slot is edited. Returns nil for an
		---unknown unit.
		function self.effectiveKeysets(unitId)
			local unit = requireBase().units[unitId]
			if not unit then
				return nil
			end
			local eff = overrides.effective(store, unit)
			local out = {}
			for i, ks in ipairs(eff) do
				out[i] = keyset.canonical(ks)
			end
			return out
		end

		---Catalog categories as { name, label } in declaration order.
		function self.listCategories()
			local out = {}
			for _, c in ipairs(cat.categories) do
				out[#out + 1] = { name = c.name, label = c.label }
			end
			return out
		end

		---Rows for the UI, in catalog order.
		function self.listUnits()
			local b = requireBase()
			local rows = {}
			for _, unitId in ipairs(b.order) do
				local unit = b.units[unitId]
				local eff, overridden = overrides.effective(store, unit)
				rows[#rows + 1] = {
					unitId = unitId,
					label = unit.entry.label,
					paramLabel = unit.paramLabel,
					tooltip = unit.entry.tooltip,
					category = unit.category,
					locked = unit.locked,
					hidden = unit.hidden,
					level = unit.level,
					discovered = unit.discovered,
					keysets = eff,
					overridden = overridden,
					drift = unit.drift,
					action = unit.action or (unit.actions and (unit.actions[1] .. " / " .. unit.actions[2])) or "",
				}
			end
			return rows
		end

		function self.overrideCount()
			local n = 0
			local t = overrides.serialize(store).presets[store.presetKey]
			if t then
				for _ in pairs(t) do
					n = n + 1
				end
			end
			return n
		end

		function self.serializeOverrides()
			return overrides.serialize(store)
		end

		function self.auditOverrides()
			return overrides.audit(store, requireBase().units)
		end

		----------------------------------------------------------------
		-- Conflicts
		----------------------------------------------------------------

		function self.allConflicts()
			return conflicts.scan(conflicts.index(requireBase(), store))
		end

		---What would binding `keysetString` on this unit collide with?
		function self.probeConflicts(unitId, keysetString)
			local b = requireBase()
			local unit = b.units[unitId]
			if not unit then
				return nil, "unknown keybind '" .. tostring(unitId) .. "'"
			end
			local ks, err = keyset.parse(keysetString)
			if not ks then
				return nil, err
			end
			local index = conflicts.index(b, store)
			return conflicts.probe(index, b.unmanaged, unit, ks)
		end

		---Validate a candidate keyset for a unit without storing anything
		---(capture-time feedback).
		function self.validateBinding(unitId, keysetString)
			local unit = requireBase().units[unitId]
			if not unit then
				return false, "unknown keybind '" .. tostring(unitId) .. "'"
			end
			if unit.locked then
				return false, "this keybind is locked"
			end
			local ks, err = keyset.parse(keysetString)
			if not ks then
				return false, err
			end
			local proc = processors.get(unit.entry.processor.type)
			return proc.validate(unit, ks)
		end

		----------------------------------------------------------------
		-- Watchdog support
		----------------------------------------------------------------

		---Compare a fresh snapshot against expectations. Returns
		---  ok (nothing off),
		---  { oursMissing  = Pair[]   our override binds that vanished,
		---    foreignAdded = Pair[]   live binds we did not expect,
		---    foreignRemoved = Pair[] expected binds gone, not ours }
		function self.diffLive(rawBinds)
			local b = requireBase()
			local live = import.normalizePairs(rawBinds)
			local liveKeys = {}
			for _, pr in ipairs(live) do
				liveKeys[compile.pairKey(pr)] = true
			end
			local expectedKeys = {}
			for _, pr in ipairs(expectedLive) do
				expectedKeys[compile.pairKey(pr)] = true
			end

			-- Our footprint: desired pairs of every overridden unit.
			local ourKeys = {}
			local oursMissing = {}
			for _, unitId in ipairs(b.order) do
				if overrides.get(store, unitId) then
					for _, pr in ipairs(currentByUnit[unitId] or {}) do
						local key = compile.pairKey(pr)
						ourKeys[key] = true
						if not liveKeys[key] then
							oursMissing[#oursMissing + 1] = pr
						end
					end
				end
			end

			local foreignAdded = {}
			for _, pr in ipairs(live) do
				if not expectedKeys[compile.pairKey(pr)] then
					foreignAdded[#foreignAdded + 1] = pr
				end
			end
			local foreignRemoved = {}
			for _, pr in ipairs(expectedLive) do
				local key = compile.pairKey(pr)
				if not liveKeys[key] and not ourKeys[key] then
					foreignRemoved[#foreignRemoved + 1] = pr
				end
			end

			local ok = #oursMissing == 0 and #foreignAdded == 0 and #foreignRemoved == 0
			return ok, {
				oursMissing = oursMissing,
				foreignAdded = foreignAdded,
				foreignRemoved = foreignRemoved,
			}
		end

		---Fold foreign drift into base + expected state WITHOUT touching
		---overrides: another widget bound something, or the user ran /bind.
		---This keeps reset-to-default semantics anchored to the preset while
		---the watchdog stops re-reporting the same drift.
		function self.absorb(diff)
			local b = requireBase()
			local removedKeys = {}
			for _, pr in ipairs(diff.foreignRemoved) do
				removedKeys[compile.pairKey(pr)] = true
			end

			local function filterList(list)
				local out = {}
				for _, pr in ipairs(list) do
					if not removedKeys[compile.pairKey(pr)] then
						out[#out + 1] = pr
					end
				end
				return out
			end

			expectedLive = filterList(expectedLive)
			for _, pr in ipairs(diff.foreignAdded) do
				expectedLive[#expectedLive + 1] = pr
			end

			-- Base and unmanaged absorb the delta too (foreign binds on
			-- managed actions stay foreign until the next full refresh; the
			-- simple, predictable choice).
			b.livePairs = filterList(b.livePairs)
			for _, pr in ipairs(diff.foreignAdded) do
				b.livePairs[#b.livePairs + 1] = pr
				b.unmanaged[#b.unmanaged + 1] = pr
			end
			b.unmanaged = filterList(b.unmanaged)
		end

		---Verify a plan landed (fresh snapshot).
		function self.verifyPlan(rawBinds, plan)
			local live = import.normalizePairs(rawBinds)
			return compile.verify(live, plan)
		end

		return self
	end

	return M
end
