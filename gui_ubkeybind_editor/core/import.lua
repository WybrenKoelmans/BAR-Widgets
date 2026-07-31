-- ubKeybind Editor — import: engine snapshot -> user-level model.
--
-- Takes the raw result of Spring.GetKeyBindings() (injected as plain tables:
-- { command, extra, boundWith }[]) plus the catalog, and produces:
--
--   units       unitId -> Unit (keysets, consumed engine pairs, drift)
--   order       unitId[] in catalog order
--   unmanaged   binds whose action matches no catalog unit — preserved
--               verbatim, never touched by the compiler
--   livePairs   the full normalized snapshot, order preserved (bind order is
--               engine behavior for keysets hosting several actions)
--   warnings    human-readable import problems (unparseable keysets etc.)
--
-- Import is pure and idempotent: it must be safe to re-run on every resync
-- (preset switch, /keyreload, widget re-enable).

return function(core)
	local keyset = core.keyset
	local catalog = core.catalog
	local processors = core.processors

	local M = {}

	---Normalize a raw GetKeyBindings dump into parsed pairs, order preserved.
	---Returns pairs (with .ks/.action/.boundWith/.index), warnings[].
	function M.normalizePairs(rawBinds)
		local warnings = {}
		local livePairs = {}

		for i, rb in ipairs(rawBinds or {}) do
			local command = rb.command or ""
			local extra = rb.extra or ""
			local actionStr = extra ~= "" and (command .. " " .. extra) or command
			local action = catalog.normalizeAction(actionStr)
			local boundWith = rb.boundWith or ""

			local ks, err = keyset.parse(boundWith)
			if not ks then
				warnings[#warnings + 1] = "unparseable keyset '" .. tostring(boundWith)
					.. "' for action '" .. action .. "': " .. tostring(err)
			elseif action == "" then
				warnings[#warnings + 1] = "bind with empty action on '" .. boundWith .. "'"
			else
				livePairs[#livePairs + 1] = {
					ks = ks,
					action = action,
					boundWith = boundWith,
					index = i,
				}
			end
		end

		return livePairs, warnings
	end

	---@param rawBinds table[]  { command, extra, boundWith }[]
	---@param cat table         result of catalog.load
	function M.run(rawBinds, cat)
		local livePairs, warnings = M.normalizePairs(rawBinds)

		local actionsSeen = {}
		for _, pr in ipairs(livePairs) do
			actionsSeen[pr.action] = true
		end

		local discovered = catalog.discoverParams(cat, actionsSeen)
		local units, order = catalog.units(cat, discovered)

		-- Exact action identity -> owning unit. Catalog validation prevents
		-- double claims, so first-wins here is just belt and braces.
		local unitByAction = {}
		for _, unitId in ipairs(order) do
			local unit = units[unitId]
			for _, a in ipairs(unit.actionIds) do
				if not unitByAction[a] then
					unitByAction[a] = unit
				end
			end
		end

		-- Bucket the snapshot per unit, preserving order.
		local unmanaged = {}
		local pools = {}
		for _, pr in ipairs(livePairs) do
			local unit = unitByAction[pr.action]
			if unit then
				local pool = pools[unit.unitId]
				if not pool then
					pool = {}
					pools[unit.unitId] = pool
				end
				pool[#pool + 1] = pr
			else
				unmanaged[#unmanaged + 1] = pr
			end
		end

		-- Run each unit's processor over its pool. Everything in the pool
		-- ends up in unit.pairs (order preserved) — what the shape could not
		-- explain is still the unit's to clean up on edit, flagged as
		-- foreign_shape.
		for _, unitId in ipairs(order) do
			local unit = units[unitId]
			local pool = pools[unitId] or {}
			local proc = processors.get(unit.entry.processor.type)

			local keysets, consumed, drift = proc.fromEngine(unit, pool)
			unit.keysets = keysets
			unit.drift = drift
			unit.pairs = {}
			for i, pr in ipairs(pool) do
				unit.pairs[#unit.pairs + 1] = pr
				if not consumed[i] then
					drift[#drift + 1] = {
						kind = "foreign_shape",
						keyset = keyset.canonical(pr.ks),
						action = pr.action,
						detail = "bind does not fit this keybind's shape; it will be removed on first edit",
					}
				end
			end
		end

		return {
			units = units,
			order = order,
			unmanaged = unmanaged,
			livePairs = livePairs,
			warnings = warnings,
		}
	end

	return M
end
