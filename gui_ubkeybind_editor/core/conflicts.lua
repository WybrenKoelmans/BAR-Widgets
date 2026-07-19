-- ubKeybind Editor — conflict detection over engine-level occupancy.
--
-- Conflicts are WARNINGS, never errors: BAR deliberately multi-binds keysets
-- for context-dependent actions. Occupancy is computed from what the
-- processors actually put in the engine (user keysets, implicit Shift
-- companions, Any wraps), so a collision "via implicit Shift companion" is
-- reported as such.
--
-- Overlap semantics come from keyset.overlaps: same chain length, same keys,
-- modifiers equal or wildcarded by Any. Chain-prefix families ("sc_l" vs
-- "sc_l,sc_l") never conflict.
--
-- scan() covers managed units only — the legacy preset stacks ~40 buildunit_*
-- binds on sc_z, and flagging base-state noise would drown the signal.
-- probe() is the capture-time point query and DOES consult the unmanaged
-- pool, so binding onto occupied territory warns before commit.

return function(core)
	local keyset = core.keyset
	local overrides = core.overrides
	local processors = core.processors

	local M = {}

	---Build the occupancy index for the current effective state.
	---Entries bucket by key signature (comma-joined bare keys): two keysets
	---can only overlap when their signatures match.
	function M.index(base, store)
		local bySig = {}
		for _, unitId in ipairs(base.order) do
			local unit = base.units[unitId]
			local eff, overridden = overrides.effective(store, unit)
			if #eff > 0 then
				local proc = processors.get(unit.entry.processor.type)
				for _, occ in ipairs(proc.occupies(unit, eff)) do
					local sig = keyset.signature(occ.ks)
					local list = bySig[sig]
					if not list then
						list = {}
						bySig[sig] = list
					end
					list[#list + 1] = {
						unitId = unitId,
						action = occ.action,
						ks = occ.ks,
						source = occ.source,
						overridden = overridden,
					}
				end
			end
		end
		return { bySig = bySig }
	end

	---All pairwise overlaps between DIFFERENT managed units where at least
	---one side is user-overridden. Base presets deliberately stack
	---context-dependent actions on one key (specteam vs group select on the
	---number row) — overlaps the USER did not cause are not warnings.
	---Returns a list of { keyset = display-agnostic canonical string,
	---a = member, b = member } entries, deterministic order.
	function M.scan(index)
		local out = {}
		local sigs = {}
		for sig in pairs(index.bySig) do
			sigs[#sigs + 1] = sig
		end
		table.sort(sigs)

		for _, sig in ipairs(sigs) do
			local list = index.bySig[sig]
			for i = 1, #list do
				for j = i + 1, #list do
					local a, b = list[i], list[j]
					if a.unitId ~= b.unitId
						and (a.overridden or b.overridden)
						and keyset.overlaps(a.ks, b.ks) then
						out[#out + 1] = {
							keyset = keyset.canonical(a.ks),
							a = a,
							b = b,
						}
					end
				end
			end
		end
		return out
	end

	---Point query for a candidate user keyset on a unit: what would its full
	---engine footprint collide with? Checks managed occupancy (excluding the
	---unit itself) AND the unmanaged pool. Returns a list of
	---{ unitId?, action, source?, via } members, where `via` is the canonical
	---footprint keyset that collides.
	function M.probe(index, unmanaged, unit, candidate)
		local proc = processors.get(unit.entry.processor.type)
		local hits = {}
		local seen = {}

		local function addHit(via, member)
			local key = (member.unitId or "?") .. "\0" .. member.action .. "\0" .. via
			if not seen[key] then
				seen[key] = true
				member.via = via
				hits[#hits + 1] = member
			end
		end

		for _, occ in ipairs(proc.occupies(unit, { candidate })) do
			local via = keyset.canonical(occ.ks)
			local sig = keyset.signature(occ.ks)

			local list = index.bySig[sig]
			if list then
				for _, entry in ipairs(list) do
					if entry.unitId ~= unit.unitId and keyset.overlaps(occ.ks, entry.ks) then
						addHit(via, {
							unitId = entry.unitId,
							action = entry.action,
							source = entry.source,
						})
					end
				end
			end

			for _, pr in ipairs(unmanaged or {}) do
				if keyset.signature(pr.ks) == sig and keyset.overlaps(occ.ks, pr.ks) then
					addHit(via, { action = pr.action, source = "unmanaged" })
				end
			end
		end

		return hits
	end

	return M
end
