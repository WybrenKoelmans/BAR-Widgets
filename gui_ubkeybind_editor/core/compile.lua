-- ubKeybind Editor — compiler: effective state -> engine command batch.
--
-- Emits commands ONLY for units whose effective state (base + override)
-- differs from what is currently live for them. compile(import(base)) with an
-- empty store is therefore an empty plan by construction — round-trip safety
-- without requiring import to be a bijection.
--
-- Removal is always the exact pair `unbind <keyset> <action>` (NEVER
-- unbindkeyset, which would kill co-bound actions). Unbinds use the engine's
-- verbatim boundWith string when we have one.
--
-- Bind order matters: the engine walks a keyset's action list in bind order,
-- and `bind` appends. When a bind is RESTORED onto a keyset that still hosts
-- other actions (e.g. reset-to-default of one of the five `esc` actions), a
-- naive append would reorder the list, so the plan rebuilds that keyset:
-- exact unbinds of every remaining pair, then rebinds in reference order
-- (base snapshot order for base pairs, current order for the rest).

return function(core)
	local keyset = core.keyset
	local overrides = core.overrides
	local processors = core.processors

	local M = {}

	---Identity of one engine bind: canonical keyset + action.
	function M.pairKey(pr)
		return keyset.canonical(pr.ks) .. "\0" .. pr.action
	end

	local function emitKeyset(pr)
		return pr.boundWith or keyset.toEngine(pr.ks)
	end

	---Desired engine pairs for a unit under the current store.
	---
	---No override: the unit keeps its BASE pairs verbatim, drift included —
	---unedited units never emit commands, which is what makes
	---compile(import(base)) a no-op. Overridden: the processor emits the
	---full proper shape (canonicalize-on-write: missing companions appear,
	---redundant plain duplicates disappear).
	function M.unitDesired(unit, store)
		local entry = overrides.get(store, unit.unitId)
		if not entry then
			return unit.pairs or {}
		end
		if entry.unbound then
			return {}
		end
		local eff = overrides.effective(store, unit)
		local proc = processors.get(unit.entry.processor.type)
		return proc.toEngine(unit, eff)
	end

	---Build the command plan.
	---@param base table          ImportResult (units/order/livePairs)
	---@param store table         override store
	---@param currentByUnit table unitId -> Pair[] currently live for that unit
	---                           (unit.pairs at startup; plan.touched after applies)
	---@param liveList table      full current live pair list, order preserved
	---@return table plan         { commands, touched, removals, additions, rebuilds }
	function M.plan(base, store, currentByUnit, liveList)
		local removals = {} -- { pair, unitId }
		local additions = {}
		local touched = {}

		for _, unitId in ipairs(base.order) do
			local unit = base.units[unitId]
			local desired = M.unitDesired(unit, store)
			local current = currentByUnit[unitId] or {}

			local desiredKeys = {}
			for _, pr in ipairs(desired) do
				desiredKeys[M.pairKey(pr)] = true
			end
			local currentKeys = {}
			for _, pr in ipairs(current) do
				currentKeys[M.pairKey(pr)] = true
			end

			local changed = false
			for _, pr in ipairs(current) do
				if not desiredKeys[M.pairKey(pr)] then
					removals[#removals + 1] = { pair = pr, unitId = unitId }
					changed = true
				end
			end
			for _, pr in ipairs(desired) do
				if not currentKeys[M.pairKey(pr)] then
					additions[#additions + 1] = { pair = pr, unitId = unitId }
					changed = true
				end
			end

			if changed then
				touched[unitId] = desired
			end
		end

		-- Base snapshot position of every base pair, for reference ordering.
		local baseIndex = {}
		for i, pr in ipairs(base.livePairs) do
			baseIndex[M.pairKey(pr)] = i
		end

		local removedKeys = {}
		for _, r in ipairs(removals) do
			removedKeys[M.pairKey(r.pair)] = true
		end

		-- Current live pairs per canonical keyset, minus planned removals.
		local liveByKs = {}
		for _, pr in ipairs(liveList or {}) do
			local key = M.pairKey(pr)
			if not removedKeys[key] then
				local canonKs = keyset.canonical(pr.ks)
				local list = liveByKs[canonKs]
				if not list then
					list = {}
					liveByKs[canonKs] = list
				end
				list[#list + 1] = pr
			end
		end

		local additionsByKs = {}
		for _, a in ipairs(additions) do
			local canonKs = keyset.canonical(a.pair.ks)
			local list = additionsByKs[canonKs]
			if not list then
				list = {}
				additionsByKs[canonKs] = list
			end
			list[#list + 1] = a.pair
		end

		-- Decide which keysets must be rebuilt to preserve reference order.
		local rebuilds = {} -- canonKs -> { unbinds = Pair[], binds = Pair[] }
		for canonKs, adds in pairs(additionsByKs) do
			local existing = liveByKs[canonKs] or {}
			if #existing > 0 then
				local final = {}
				for _, pr in ipairs(existing) do
					final[#final + 1] = pr
				end
				for _, pr in ipairs(adds) do
					final[#final + 1] = pr
				end

				-- Reference order: base pairs by base position, then the rest
				-- in their current order.
				local basePart, restPart = {}, {}
				for _, pr in ipairs(final) do
					if baseIndex[M.pairKey(pr)] then
						basePart[#basePart + 1] = pr
					else
						restPart[#restPart + 1] = pr
					end
				end
				table.sort(basePart, function(a, b)
					return baseIndex[M.pairKey(a)] < baseIndex[M.pairKey(b)]
				end)
				local target = {}
				for _, pr in ipairs(basePart) do
					target[#target + 1] = pr
				end
				for _, pr in ipairs(restPart) do
					target[#target + 1] = pr
				end

				-- Naive append = existing order ++ additions. Rebuild only
				-- when the target differs.
				local same = true
				for i = 1, #final do
					if M.pairKey(final[i]) ~= M.pairKey(target[i]) then
						same = false
						break
					end
				end
				if not same then
					rebuilds[canonKs] = { unbinds = existing, binds = target }
				end
			end
		end

		-- Emit: all exact removals, then rebuild blocks, then plain binds.
		local commands = {}
		for _, r in ipairs(removals) do
			commands[#commands + 1] = "unbind " .. emitKeyset(r.pair) .. " " .. r.pair.action
		end
		local rebuiltKs = {}
		local rebuildOrder = {}
		for canonKs in pairs(rebuilds) do
			rebuiltKs[canonKs] = true
			rebuildOrder[#rebuildOrder + 1] = canonKs
		end
		table.sort(rebuildOrder)
		for _, canonKs in ipairs(rebuildOrder) do
			local rb = rebuilds[canonKs]
			for _, pr in ipairs(rb.unbinds) do
				commands[#commands + 1] = "unbind " .. emitKeyset(pr) .. " " .. pr.action
			end
			for _, pr in ipairs(rb.binds) do
				commands[#commands + 1] = "bind " .. emitKeyset(pr) .. " " .. pr.action
			end
		end
		for _, a in ipairs(additions) do
			if not rebuiltKs[keyset.canonical(a.pair.ks)] then
				commands[#commands + 1] = "bind " .. keyset.toEngine(a.pair.ks) .. " " .. a.pair.action
			end
		end

		return {
			commands = commands,
			touched = touched,
			removals = removals,
			additions = additions,
			rebuilds = rebuilds,
		}
	end

	---Project the plan onto a live pair list: what the engine should contain
	---after the batch lands. Order approximates engine behavior (rebuild
	---targets in their target order, fresh binds appended).
	function M.applyExpected(liveList, plan)
		local removedKeys = {}
		for _, r in ipairs(plan.removals) do
			removedKeys[M.pairKey(r.pair)] = true
		end

		local out = {}
		local rebuiltDone = {}
		for _, pr in ipairs(liveList or {}) do
			local canonKs = keyset.canonical(pr.ks)
			local rb = plan.rebuilds[canonKs]
			if rb then
				if not rebuiltDone[canonKs] then
					rebuiltDone[canonKs] = true
					for _, p in ipairs(rb.binds) do
						out[#out + 1] = p
					end
				end
				-- original members of a rebuilt keyset are dropped here
			elseif not removedKeys[M.pairKey(pr)] then
				out[#out + 1] = pr
			end
		end
		for _, a in ipairs(plan.additions) do
			local canonKs = keyset.canonical(a.pair.ks)
			if not plan.rebuilds[canonKs] then
				out[#out + 1] = a.pair
			end
		end
		return out
	end

	---Check a fresh snapshot against a plan: every desired pair of every
	---touched unit present, every removal absent. Returns ok, details.
	function M.verify(rawPairs, plan)
		local liveKeys = {}
		for _, pr in ipairs(rawPairs) do
			liveKeys[M.pairKey(pr)] = true
		end

		local missing, stale = {}, {}
		for unitId, desired in pairs(plan.touched) do
			for _, pr in ipairs(desired) do
				if not liveKeys[M.pairKey(pr)] then
					missing[#missing + 1] = { unitId = unitId, pair = pr }
				end
			end
		end
		for _, r in ipairs(plan.removals) do
			if liveKeys[M.pairKey(r.pair)] then
				stale[#stale + 1] = r
			end
		end
		-- Rebuild unbind targets that were not re-bound must also be gone;
		-- they are covered by removals/touched above by construction.

		return #missing == 0 and #stale == 0, { missing = missing, stale = stale }
	end

	return M
end
