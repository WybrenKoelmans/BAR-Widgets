-- ubKeybind Editor — binding-shape processors.
--
-- A processor is the bidirectional transform between ONE user-facing keybind
-- and the engine binds that implement it. The four shapes are mutually
-- exclusive (Any subsumes Shift, so wrapping and shifting never compose);
-- parameterization is handled by catalog expansion before processors run, and
-- keychains are a keyset property (withShift maps over every press).
--
--   direct       bind ks action
--   auto_shift   bind ks action        + bind Shift(ks) action     (queue copy)
--   queued_pair  bind ks actions[1]    + bind Shift(ks) actions[2]
--   any_wrap     bind Any(ks) action
--
-- Contract (all functions stateless):
--   validate(def, ks)        -> ok, reason
--   toEngine(def, keysets)   -> Pair[]         Pair = { ks = Keyset, action = string }
--   fromEngine(def, pool)    -> keysets, consumed, drift
--       pool: Pair-like entries for this unit's action(s) ONLY, snapshot order.
--       consumed: set of pool indices this shape explains (they belong to the
--       unit and are cleaned up on its first edit). Entries it cannot explain
--       are left unconsumed; the importer absorbs them with "foreign_shape".
--       drift: { kind, keyset, action, detail? }[] — warnings, never errors.
--   occupies(def, keysets)   -> { ks, action, source }[]  engine-level
--       footprint for conflict detection (source: user|companion|any_wrap).
--
-- Closure law (tested): fromEngine(def, toEngine(def, ks)) == ks, no drift.
--
-- def fields used here: def.action (direct/auto_shift/any_wrap, param already
-- substituted) or def.actions = { base, queued } (queued_pair).

return function(core)
	local keyset = core.keyset

	local M = {}
	local registry = {}

	function M.get(typeName)
		local p = registry[typeName]
		if not p then
			error("unknown processor type '" .. tostring(typeName) .. "'")
		end
		return p
	end

	function M.isKnown(typeName)
		return registry[typeName] ~= nil
	end

	local function drift(kind, ks, action, detail)
		return {
			kind = kind,
			keyset = keyset.canonical(ks),
			action = action,
			detail = detail,
		}
	end

	----------------------------------------------------------------------
	-- direct: one keyset, one bind.
	----------------------------------------------------------------------
	registry.direct = {
		validate = function(def, ks)
			return true
		end,

		toEngine = function(def, keysets)
			local out = {}
			for _, ks in ipairs(keysets) do
				out[#out + 1] = { ks = ks, action = def.action }
			end
			return out
		end,

		fromEngine = function(def, pool)
			local keysets, consumed, drifts = {}, {}, {}
			local seen = {} ---@type table<string, true>
			for i, pr in ipairs(pool) do
				consumed[i] = true
				local canon = keyset.canonical(pr.ks)
				if seen[canon] then
					drifts[#drifts + 1] = drift("duplicate", pr.ks, pr.action)
				else
					seen[canon] = true
					keysets[#keysets + 1] = pr.ks
				end
			end
			return keysets, consumed, drifts
		end,

		occupies = function(def, keysets)
			local out = {}
			for _, ks in ipairs(keysets) do
				out[#out + 1] = { ks = ks, action = def.action, source = "user" }
			end
			return out
		end,
	}

	----------------------------------------------------------------------
	-- auto_shift: same action bound plain and with an implicit Shift copy
	-- (the queue variant). The user only ever sees the plain keyset.
	----------------------------------------------------------------------
	registry.auto_shift = {
		validate = function(def, ks)
			if keyset.hasShift(ks) then
				return false, "Shift is reserved for the queue variant of this keybind"
			end
			if keyset.hasAny(ks) then
				return false, "the Any modifier cannot be used for this keybind"
			end
			return true
		end,

		toEngine = function(def, keysets)
			local out = {}
			for _, ks in ipairs(keysets) do
				out[#out + 1] = { ks = ks, action = def.action }
				out[#out + 1] = { ks = keyset.withShift(ks), action = def.action }
			end
			return out
		end,

		fromEngine = function(def, pool)
			local keysets, consumed, drifts = {}, {}, {}

			-- Shifted binds indexed by canonical form, for companion pairing.
			local shiftedIdx = {} ---@type table<string, integer[]>
			for i, pr in ipairs(pool) do
				if not keyset.hasAny(pr.ks) and keyset.hasShift(pr.ks) then
					local canon = keyset.canonical(pr.ks)
					shiftedIdx[canon] = shiftedIdx[canon] or {}
					table.insert(shiftedIdx[canon], i)
				end
			end

			local seen = {} ---@type table<string, true>
			for i, pr in ipairs(pool) do
				if keyset.hasAny(pr.ks) then
					-- Any-modified bind under an auto_shift shape: not ours to
					-- explain; the importer absorbs it as foreign_shape.
					-- (Catalog should classify such actions as any_wrap.)
				elseif not keyset.hasShift(pr.ks) then
					consumed[i] = true
					local canon = keyset.canonical(pr.ks)
					if seen[canon] then
						drifts[#drifts + 1] = drift("duplicate", pr.ks, pr.action)
					else
						seen[canon] = true
						keysets[#keysets + 1] = pr.ks
						local compCanon = keyset.canonical(keyset.withShift(pr.ks))
						local comp = shiftedIdx[compCanon]
						if comp and #comp > 0 then
							consumed[table.remove(comp, 1)] = true
						else
							drifts[#drifts + 1] = drift("missing_companion", pr.ks, pr.action,
								"no Shift queue copy in base; it will be generated on first edit")
						end
					end
				end
			end

			-- Shifted binds with no plain partner: they violate the shape's
			-- validation rule, so they cannot become user keysets. Consume
			-- them (they belong to this action and get cleaned up on edit).
			for _, list in pairs(shiftedIdx) do
				for _, i in ipairs(list) do
					if not consumed[i] then
						consumed[i] = true
						drifts[#drifts + 1] = drift("orphan_companion", pool[i].ks, pool[i].action,
							"Shift-only bind without a plain partner")
					end
				end
			end

			return keysets, consumed, drifts
		end,

		occupies = function(def, keysets)
			local out = {}
			for _, ks in ipairs(keysets) do
				out[#out + 1] = { ks = ks, action = def.action, source = "user" }
				out[#out + 1] = { ks = keyset.withShift(ks), action = def.action, source = "companion" }
			end
			return out
		end,
	}

	----------------------------------------------------------------------
	-- queued_pair: two actions, base on the user keyset and the queued
	-- variant on its implicit Shift copy ("selfd" / "selfd queued").
	----------------------------------------------------------------------
	registry.queued_pair = {
		validate = function(def, ks)
			if keyset.hasShift(ks) then
				return false, "Shift is reserved for the queue variant of this keybind"
			end
			if keyset.hasAny(ks) then
				return false, "the Any modifier cannot be used for this keybind"
			end
			return true
		end,

		toEngine = function(def, keysets)
			local out = {}
			for _, ks in ipairs(keysets) do
				out[#out + 1] = { ks = ks, action = def.actions[1] }
				out[#out + 1] = { ks = keyset.withShift(ks), action = def.actions[2] }
			end
			return out
		end,

		fromEngine = function(def, pool)
			local base, queued = def.actions[1], def.actions[2]
			local keysets, consumed, drifts = {}, {}, {}

			local queuedIdx = {} ---@type table<string, integer[]>
			for i, pr in ipairs(pool) do
				if pr.action == queued and not keyset.hasAny(pr.ks) then
					local canon = keyset.canonical(pr.ks)
					queuedIdx[canon] = queuedIdx[canon] or {}
					table.insert(queuedIdx[canon], i)
				end
			end

			local seen = {} ---@type table<string, true>
			for i, pr in ipairs(pool) do
				if pr.action == base and not keyset.hasAny(pr.ks) and not keyset.hasShift(pr.ks) then
					consumed[i] = true
					local canon = keyset.canonical(pr.ks)
					if seen[canon] then
						drifts[#drifts + 1] = drift("duplicate", pr.ks, pr.action)
					else
						seen[canon] = true
						keysets[#keysets + 1] = pr.ks
						local compCanon = keyset.canonical(keyset.withShift(pr.ks))
						local comp = queuedIdx[compCanon]
						if comp and #comp > 0 then
							consumed[table.remove(comp, 1)] = true
						else
							drifts[#drifts + 1] = drift("missing_companion", pr.ks, base,
								"no '" .. queued .. "' bind on the Shift copy; it will be generated on first edit")
						end
					end
				end
				-- Base action WITH Shift is off-shape: left for foreign_shape.
			end

			-- Queued binds not matched to a base keyset: mislocated
			-- companions. Consume them so edits clean them up.
			for _, list in pairs(queuedIdx) do
				for _, i in ipairs(list) do
					if not consumed[i] then
						consumed[i] = true
						drifts[#drifts + 1] = drift("orphan_companion", pool[i].ks, pool[i].action,
							"queued variant bound away from the base keyset's Shift copy")
					end
				end
			end

			return keysets, consumed, drifts
		end,

		occupies = function(def, keysets)
			local out = {}
			for _, ks in ipairs(keysets) do
				out[#out + 1] = { ks = ks, action = def.actions[1], source = "user" }
				out[#out + 1] = { ks = keyset.withShift(ks), action = def.actions[2], source = "companion" }
			end
			return out
		end,
	}

	----------------------------------------------------------------------
	-- any_wrap: bound with the Any modifier so it fires regardless of the
	-- modifier state. User keysets are bare keys.
	----------------------------------------------------------------------
	registry.any_wrap = {
		validate = function(def, ks)
			if keyset.hasMods(ks) then
				return false, "this keybind ignores modifiers — choose a key without them"
			end
			return true
		end,

		toEngine = function(def, keysets)
			local out = {}
			for _, ks in ipairs(keysets) do
				out[#out + 1] = { ks = keyset.withAny(ks), action = def.action }
			end
			return out
		end,

		fromEngine = function(def, pool)
			local keysets, consumed, drifts = {}, {}, {}
			local seen = {} ---@type table<string, true>

			-- Pass 1: Any-form binds (the shape's real footprint).
			for i, pr in ipairs(pool) do
				if keyset.hasAny(pr.ks) then
					local bare = keyset.stripAny(pr.ks)
					if keyset.hasMods(bare) then
						-- Any combined with other modifiers: off-shape,
						-- leave for foreign_shape absorption.
					else
						consumed[i] = true
						local canon = keyset.canonical(bare)
						if seen[canon] then
							drifts[#drifts + 1] = drift("duplicate", pr.ks, pr.action)
						else
							seen[canon] = true
							keysets[#keysets + 1] = bare
						end
					end
				end
			end

			-- Pass 2: plain binds. A modifier-free duplicate of an Any bind is
			-- redundant (grid_keys binds wantcloak both ways); a plain bind
			-- without an Any form still becomes a user keyset and gets
			-- canonicalized to Any on first edit.
			for i, pr in ipairs(pool) do
				if not keyset.hasAny(pr.ks) and not keyset.hasMods(pr.ks) then
					consumed[i] = true
					local canon = keyset.canonical(pr.ks)
					if seen[canon] then
						drifts[#drifts + 1] = drift("redundant_plain", pr.ks, pr.action,
							"plain duplicate of an Any+ bind; it will be removed on first edit")
					else
						seen[canon] = true
						keysets[#keysets + 1] = pr.ks
						drifts[#drifts + 1] = drift("missing_any_wrap", pr.ks, pr.action,
							"bound without Any in base; it will be wrapped on first edit")
					end
				end
				-- Modifier-carrying plain binds are off-shape: foreign_shape.
			end

			return keysets, consumed, drifts
		end,

		occupies = function(def, keysets)
			local out = {}
			for _, ks in ipairs(keysets) do
				out[#out + 1] = { ks = keyset.withAny(ks), action = def.action, source = "any_wrap" }
			end
			return out
		end,
	}

	return M
end
