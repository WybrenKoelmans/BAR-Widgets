-- ubKeybind Editor — catalog loading, validation and unit expansion.
--
-- The catalog (keybinds_catalog.json, schema v2) declares every user-facing
-- keybind: label, category, tooltip and the processor shape that maps it to
-- engine binds. It carries NO key assignments — defaults come from importing
-- the live preset through the processors.
--
-- Parameterized entries ("group select" -> "group select 0".."9") expand into
-- UNITS: one unit per (entry, param). Non-parameterized entries are one unit.
-- Unit identity: entry.id, or entry.id .. "/" .. param.
--
-- Bad entries are skipped with an error string rather than failing the whole
-- catalog; the editor should stay usable when one entry regresses.

return function(core)
	local processors = core.processors
	local unpack = unpack or table.unpack -- Lua 5.1 (Spring) / newer interpreters

	local M = {}

	-- Visibility tiers, cumulative: selecting a tier in the UI shows it and
	-- everything ranked below it (Advanced shows Common+Uncommon+Advanced,
	-- not "all"). "all" is the escape hatch for obscure/unused binds that
	-- should stay out of the way otherwise. Unclassified entries default to
	-- "common" so nothing hides by accident.
	M.LEVELS = { "common", "uncommon", "advanced", "all" }
	local LEVEL_RANK = { common = 1, uncommon = 2, advanced = 3, all = 4 }

	---Ordinal rank of a level name, for cumulative "show up to this tier"
	---comparisons. Unknown/nil levels rank as "common" (most visible).
	function M.levelRank(level)
		return LEVEL_RANK[level] or LEVEL_RANK.common
	end

	---Trim, collapse whitespace runs, and lowercase ONLY the leading command
	---token. THE action identity used everywhere (the engine dispatches the
	---command case-insensitively, but many commands — `select`, `chain` —
	---pass everything after it through verbatim to a case-sensitive
	---sub-parser; lowercasing the whole string corrupts those, e.g. `select
	---AllMap+...` breaks as `select allmap+...` — "Unknown source token").
	function M.normalizeAction(s)
		s = tostring(s):gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
		local command, rest = s:match("^(%S+)(.*)$")
		if not command then
			return s:lower()
		end
		return command:lower() .. rest
	end

	local function normalizeParam(s)
		return (tostring(s):gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " "))
	end

	local function validateEntry(raw, categoryName, byId, claimedActions, errs)
		local where = "entry '" .. tostring(raw.id or raw.label or "?") .. "' in category '" .. categoryName .. "'"

		if type(raw.id) ~= "string" or raw.id == "" then
			errs[#errs + 1] = where .. ": missing id"
			return nil
		end
		if byId[raw.id] then
			errs[#errs + 1] = where .. ": duplicate id"
			return nil
		end
		if type(raw.label) ~= "string" or raw.label == "" then
			errs[#errs + 1] = where .. ": missing label"
			return nil
		end
		local proc = raw.processor
		if type(proc) ~= "table" or type(proc.type) ~= "string" then
			errs[#errs + 1] = where .. ": missing processor.type"
			return nil
		end
		if not processors.isKnown(proc.type) then
			errs[#errs + 1] = where .. ": unknown processor type '" .. proc.type .. "'"
			return nil
		end

		local level = raw.level
		if level == nil then
			level = "common"
		elseif type(level) ~= "string" or not LEVEL_RANK[level] then
			errs[#errs + 1] = where .. ": invalid level '" .. tostring(level)
				.. "' (expected common/uncommon/advanced/all)"
			return nil
		end

		local entry = {
			id = raw.id,
			label = raw.label,
			tooltip = type(raw.tooltip) == "string" and raw.tooltip or nil,
			locked = raw.locked == true,
			hidden = raw.hidden == true,
			level = level,
			category = categoryName,
			processor = { type = proc.type },
		}

		if proc.type == "queued_pair" then
			if type(proc.actions) ~= "table" or type(proc.actions[1]) ~= "string" or type(proc.actions[2]) ~= "string" then
				errs[#errs + 1] = where .. ": queued_pair needs processor.actions = [base, queued]"
				return nil
			end
			entry.processor.actions = {
				M.normalizeAction(proc.actions[1]),
				M.normalizeAction(proc.actions[2]),
			}
			if raw.params ~= nil then
				errs[#errs + 1] = where .. ": params are not supported for queued_pair"
				return nil
			end
		else
			if type(proc.action) ~= "string" or proc.action == "" then
				errs[#errs + 1] = where .. ": missing processor.action"
				return nil
			end
			entry.processor.action = M.normalizeAction(proc.action)
		end

		if raw.params ~= nil then
			local p = raw.params
			if type(p) ~= "table" then
				errs[#errs + 1] = where .. ": params must be an object"
				return nil
			end
			local values = {}
			if p.values ~= nil then
				if type(p.values) ~= "table" then
					errs[#errs + 1] = where .. ": params.values must be an array"
					return nil
				end
				local seen = {}
				for _, v in ipairs(p.values) do
					local param = normalizeParam(v)
					if param ~= "" and not seen[param] then
						seen[param] = true
						values[#values + 1] = param
					end
				end
			end
			entry.params = {
				values = values,
				-- Discovery from the live snapshot defaults ON so hand-added
				-- family members (e.g. extra camera anchors) surface.
				discover = p.discover ~= false,
				labelFormat = type(p.labelFormat) == "string" and p.labelFormat or nil,
			}
		end

		-- Claimed-action bookkeeping: two entries must not own one action.
		local claims = {}
		if entry.processor.actions then
			claims[1] = entry.processor.actions[1]
			claims[2] = entry.processor.actions[2]
		elseif entry.params then
			claims[1] = entry.processor.action .. " *" -- family prefix marker
		else
			claims[1] = entry.processor.action
		end
		for _, a in ipairs(claims) do
			if claimedActions[a] then
				errs[#errs + 1] = where .. ": action '" .. a .. "' already claimed by entry '" .. claimedActions[a] .. "'"
				return nil
			end
			claimedActions[a] = entry.id
		end

		return entry
	end

	---Load and validate a decoded catalog table (schema v2).
	---Returns cat, errs[]. Bad entries are skipped and reported; cat is nil
	---only when the document itself is unusable.
	function M.load(tbl)
		local errs = {}
		if type(tbl) ~= "table" then
			return nil, { "catalog is not a table" }
		end
		if tbl.version ~= 2 then
			return nil, { "catalog version must be 2 (got " .. tostring(tbl.version) .. ")" }
		end
		if type(tbl.categories) ~= "table" then
			return nil, { "catalog has no categories array" }
		end

		local cat = {
			categories = {},
			entriesById = {},
		}

		local claimedActions = {}
		for _, rawCat in ipairs(tbl.categories) do
			if type(rawCat) ~= "table" or type(rawCat.name) ~= "string" then
				errs[#errs + 1] = "category without a name skipped"
			else
				local category = {
					name = rawCat.name,
					label = type(rawCat.label) == "string" and rawCat.label or rawCat.name,
					entries = {},
				}
				for _, rawEntry in ipairs(rawCat.entries or {}) do
					local entry = validateEntry(rawEntry, category.name, cat.entriesById, claimedActions, errs)
					if entry then
						cat.entriesById[entry.id] = entry
						category.entries[#category.entries + 1] = entry
					end
				end
				cat.categories[#cat.categories + 1] = category
			end
		end

		cat.claimedActions = claimedActions
		return cat, errs
	end

	local WIDGET_ACTIONS_CATEGORY = "widget_actions"

	---Merge actions that installed widgets registered via widgetHandler:AddAction
	---(discovered live, outside the static catalog) into a synthetic "Custom
	---Widget Actions" category — one direct-processor entry per action not
	---already claimed by a real catalog entry. Everything downstream (units
	---expansion, import matching, override store, compiler, conflicts) treats
	---these exactly like any other catalog entry.
	---`discovered`: action (string) -> widgetNames (string[]), or nil.
	function M.mergeWidgetActions(cat, discovered)
		if not discovered or not next(discovered) then
			return
		end
		local claimed = cat.claimedActions
		local entries = {}
		for action, widgetNames in pairs(discovered) do
			local normalized = M.normalizeAction(action)
			local id = "widget:" .. normalized
			-- Parameterized entries claim "<action> *" (family marker), not
			-- the bare action, since the real command carries a param suffix
			-- at runtime (e.g. "add_to_autogroup 3"). Check both forms.
			if not claimed[normalized] and not claimed[normalized .. " *"] and not cat.entriesById[id] then
				claimed[normalized] = id
				local entry = {
					id = id,
					label = action,
					tooltip = "Registered by widget: " .. table.concat(widgetNames, ", "),
					locked = false,
					hidden = false,
					level = "common",
					category = WIDGET_ACTIONS_CATEGORY,
					processor = { type = "direct", action = normalized },
					source = "widget",
				}
				entries[#entries + 1] = entry
				cat.entriesById[id] = entry
			end
		end
		if #entries == 0 then
			return
		end
		table.sort(entries, function(a, b) return a.label < b.label end)
		cat.categories[#cat.categories + 1] = {
			name = WIDGET_ACTIONS_CATEGORY,
			label = "Custom Widget Actions",
			entries = entries,
		}
	end

	-- Token-wise numeric-aware comparison for discovered params, so
	-- "2" < "10" and "1 2" < "1 10".
	local function paramLess(a, b)
		local ai, bi = a:gmatch("%S+"), b:gmatch("%S+")
		while true do
			local at, bt = ai(), bi()
			if at == nil and bt == nil then
				return false
			end
			if at == nil then
				return true
			end
			if bt == nil then
				return false
			end
			local an, bn = tonumber(at), tonumber(bt)
			if an and bn then
				if an ~= bn then
					return an < bn
				end
			elseif at ~= bt then
				return at < bt
			end
		end
	end

	---Scan the set of action identities seen in a snapshot for members of
	---parameterized families. Returns entryId -> sorted param list.
	function M.discoverParams(cat, actionsSeen)
		local out = {}
		for _, category in ipairs(cat.categories) do
			for _, entry in ipairs(category.entries) do
				if entry.params and entry.params.discover then
					local prefix = entry.processor.action .. " "
					local plen = #prefix
					local found = {}
					for action in pairs(actionsSeen) do
						if action:sub(1, plen) == prefix then
							local param = normalizeParam(action:sub(plen + 1))
							if param ~= "" then
								found[#found + 1] = param
							end
						end
					end
					table.sort(found, paramLess)
					out[entry.id] = found
				end
			end
		end
		return out
	end

	local function formatParamLabel(fmt, param)
		if not fmt then
			return param
		end
		local tokens = {}
		for t in param:gmatch("%S+") do
			tokens[#tokens + 1] = t
		end
		local ok, res = pcall(string.format, fmt, unpack(tokens))
		if ok then
			return res
		end
		return param
	end

	local function makeUnit(entry, param, discovered)
		local unit = {
			entry = entry,
			locked = entry.locked,
			hidden = entry.hidden,
			level = entry.level,
			category = entry.category,
		}
		if param then
			unit.unitId = entry.id .. "/" .. param
			unit.param = param
			unit.paramLabel = formatParamLabel(entry.params.labelFormat, param)
			unit.discovered = discovered or nil
			unit.action = entry.processor.action .. " " .. param
			unit.actionIds = { unit.action }
		else
			unit.unitId = entry.id
			if entry.processor.actions then
				unit.actions = entry.processor.actions
				unit.actionIds = { entry.processor.actions[1], entry.processor.actions[2] }
			else
				unit.action = entry.processor.action
				unit.actionIds = { entry.processor.action }
			end
		end
		return unit
	end

	---Expand the catalog into units, in catalog order. Parameterized entries
	---produce one unit per param: listed values first (their order), then
	---discovered extras (sorted), deduplicated.
	---`discoveredParams` comes from M.discoverParams (may be nil).
	function M.units(cat, discoveredParams)
		discoveredParams = discoveredParams or {}
		local units, order = {}, {}

		local function add(unit)
			units[unit.unitId] = unit
			order[#order + 1] = unit.unitId
		end

		for _, category in ipairs(cat.categories) do
			for _, entry in ipairs(category.entries) do
				if not entry.params then
					add(makeUnit(entry))
				else
					local emitted = {}
					for _, param in ipairs(entry.params.values) do
						emitted[param] = true
						add(makeUnit(entry, param, false))
					end
					for _, param in ipairs(discoveredParams[entry.id] or {}) do
						if not emitted[param] then
							emitted[param] = true
							add(makeUnit(entry, param, true))
						end
					end
				end
			end
		end

		return units, order
	end

	return M
end
