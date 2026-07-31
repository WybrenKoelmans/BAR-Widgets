-- ubKeybind Editor — override store.
--
-- The ONLY persisted state: per-unit deviations from the preset base,
-- namespaced per preset file (a keyset that is free in Grid may be
-- load-bearing in Legacy). Semantics per unit:
--
--   { keysets = { "sc_a", "ctrl+sc_x" } }   full replacement of the slot list
--   { unbound = true }                      explicitly no bindings
--   (absent)                                inherit the preset base
--
-- Keysets are stored as canonical strings. Sets that equal the unit's base
-- are dropped at set() time so the store stays minimal and "overridden"
-- markers stay honest.

return function(core)
	local keyset = core.keyset

	local M = {}

	-- A keyset string containing a doubled "sc_" prefix (e.g. "sc_sc_a") can
	-- never be a real engine key; it's the signature of the fromCapture
	-- double-prefix bug (fixed 2026-07-19). Persisted junk from before the
	-- fix would otherwise wedge a unit forever (compile keeps re-emitting an
	-- unbind the engine can never satisfy), so it's dropped on load instead
	-- of trusted.
	--
	-- Multi-press chains are NOT flagged here even though the engine's
	-- `unbind` command can never remove one (confirmed against the engine
	-- source: `Bind` splits on commas via ParseKeyChain, `UnBind` doesn't) —
	-- that's not data corruption, `runtime/engine_sync.lua` handles it by
	-- redirecting a chain-removing plan through a pristine reload instead of
	-- sending a doomed unbind command.
	local function isCorruptKeyset(s)
		return type(s) == "string" and s:lower():find("sc_sc_", 1, true) ~= nil
	end

	---@param persisted table|nil  previously serialized store (tolerates junk)
	---@param presetKey string     the engine "KeybindingFile" config string
	---Returns store, sanitized[] -- sanitized entries are "presetKey/unitId"
	---strings for units whose persisted override contained an unparseable
	---keyset and were reset to inherit the base instead.
	function M.new(persisted, presetKey)
		local data = { presets = {} }
		local sanitized = {}
		if type(persisted) == "table" and type(persisted.presets) == "table" then
			for pk, entries in pairs(persisted.presets) do
				if type(pk) == "string" and type(entries) == "table" then
					local clean = {}
					for unitId, entry in pairs(entries) do
						if type(unitId) == "string" and type(entry) == "table" then
							if entry.unbound == true then
								clean[unitId] = { unbound = true }
							elseif type(entry.keysets) == "table" then
								local list = {}
								local hadCorrupt = false
								for _, s in ipairs(entry.keysets) do
									if type(s) == "string" then
										if isCorruptKeyset(s) then
											hadCorrupt = true
										else
											list[#list + 1] = s
										end
									end
								end
								if #list > 0 then
									clean[unitId] = { keysets = list }
								end
								if hadCorrupt then
									sanitized[#sanitized + 1] = pk .. "/" .. unitId
								end
							end
						end
					end
					data.presets[pk] = clean
				end
			end
		end
		return {
			data = data,
			presetKey = presetKey or "",
		}, sanitized
	end

	function M.setPreset(store, presetKey)
		store.presetKey = presetKey or ""
	end

	local function presetTable(store, create)
		local t = store.data.presets[store.presetKey]
		if not t and create then
			t = {}
			store.data.presets[store.presetKey] = t
		end
		return t
	end

	function M.get(store, unitId)
		local t = presetTable(store, false)
		return t and t[unitId] or nil
	end

	function M.clear(store, unitId)
		local t = presetTable(store, false)
		if t then
			t[unitId] = nil
		end
	end

	function M.clearAll(store)
		store.data.presets[store.presetKey] = nil
	end

	-- Order-insensitive canonical multiset comparison.
	local function sameKeysetSet(canonListA, canonListB)
		if #canonListA ~= #canonListB then
			return false
		end
		local counts = {}
		for _, c in ipairs(canonListA) do
			counts[c] = (counts[c] or 0) + 1
		end
		for _, c in ipairs(canonListB) do
			local n = counts[c]
			if not n then
				return false
			end
			counts[c] = n - 1
			if counts[c] == 0 then
				counts[c] = nil
			end
		end
		return next(counts) == nil
	end

	local function canonList(keysets)
		local out = {}
		for i, ks in ipairs(keysets) do
			out[i] = keyset.canonical(ks)
		end
		return out
	end

	---Set a unit's bindings from keyset strings (full replacement).
	---Validates each keyset against the unit's processor; a set that equals
	---the base clears the override instead; an empty set means "unbound".
	---Returns ok, err.
	function M.set(store, unit, proc, keysetStrings)
		if unit.locked then
			return false, "this keybind is locked"
		end

		local parsed = {}
		local canons = {}
		local seen = {}
		for _, s in ipairs(keysetStrings) do
			local ks, err = keyset.parse(s)
			if not ks then
				return false, "invalid keyset '" .. tostring(s) .. "': " .. tostring(err)
			end
			local ok, reason = proc.validate(unit, ks)
			if not ok then
				return false, reason
			end
			local canon = keyset.canonical(ks)
			if not seen[canon] then
				seen[canon] = true
				parsed[#parsed + 1] = ks
				canons[#canons + 1] = canon
			end
		end

		local baseCanons = canonList(unit.keysets or {})
		if sameKeysetSet(canons, baseCanons) then
			M.clear(store, unit.unitId)
			return true
		end

		local t = presetTable(store, true)
		if #canons == 0 then
			t[unit.unitId] = { unbound = true }
		else
			t[unit.unitId] = { keysets = canons }
		end
		return true
	end

	---Effective keysets for a unit: the override if present, else the base.
	---Returns Keyset[], overridden.
	function M.effective(store, unit)
		local entry = M.get(store, unit.unitId)
		if not entry then
			return unit.keysets or {}, false
		end
		if entry.unbound then
			return {}, true
		end
		local out = {}
		for _, s in ipairs(entry.keysets) do
			local ks = keyset.parse(s)
			if ks then
				out[#out + 1] = ks
			end
		end
		return out, true
	end

	---Plain table for persistence (widget GetConfigData).
	function M.serialize(store)
		return store.data
	end

	---Report override entries that reference units missing from the current
	---base (orphans: params that vanished, renamed catalog ids). They are
	---kept but never compiled.
	function M.audit(store, unitsById)
		local orphans = {}
		local t = presetTable(store, false)
		if t then
			for unitId in pairs(t) do
				if not unitsById[unitId] then
					orphans[#orphans + 1] = unitId
				end
			end
		end
		table.sort(orphans)
		return orphans
	end

	return M
end
