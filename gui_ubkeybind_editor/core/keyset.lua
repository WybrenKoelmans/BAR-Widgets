-- ubKeybind Editor — keyset parsing, normalization and comparison.
--
-- A keyset is the engine's key-combo grammar:
--   "Ctrl+Shift+sc_b"            one press, modifiers + key
--   "sc_b,sc_b"                  keychain: comma-separated presses (double-tap)
--   "Shift+sc_b,Shift+sc_b"      each press carries its own modifiers
--   "Any+space"                  Any = matches every modifier state
--   "Alt+numpad+"                keys may end in a literal '+'
--   "Any+shift"                  the last '+' segment is the key, even if it
--                                spells a modifier name
--
-- Parsed form:
--   Press  = { mods = { any=?, alt=?, ctrl=?, meta=?, shift=? }, key = string }
--   Keyset = { presses = Press[] }   -- treat as immutable
--
-- canonical() is THE identity: lowercase, fixed modifier order, key aliases
-- applied (esc == escape). Aliases are never written into emitted commands;
-- toEngine() formats from the parsed key as given.

return function(core)
	local M = {}

	local MOD_ORDER = { "any", "alt", "ctrl", "meta", "shift" }
	local IS_MOD = { any = true, alt = true, ctrl = true, meta = true, shift = true }
	local MOD_TITLE = { any = "Any", alt = "Alt", ctrl = "Ctrl", meta = "Meta", shift = "Shift" }

	-- Applied for canonical()/equality only. Maps alias -> canonical member.
	local KEY_ALIASES = {
		esc = "escape",
		enter = "return",
		del = "delete",
		ins = "insert",
		pgup = "pageup",
		pgdn = "pagedown",
		bs = "backspace",
	}

	-- Keys whose engine name is position-invariant; capture prefers the key
	-- symbol over the scancode for these (matches BAR preset conventions:
	-- presets spell letters/punctuation as sc_*, named keys bare).
	local INVARIANT_KEYS = {
		space = true, tab = true, escape = true, esc = true, ["return"] = true,
		enter = true, backspace = true, delete = true, insert = true,
		home = true, ["end"] = true, pageup = true, pagedown = true,
		up = true, down = true, left = true, right = true,
		pause = true, numlock = true, capslock = true, scrolllock = true,
		printscreen = true,
	}

	-- Physical modifier key names -> the bare modifier key the engine binds
	-- (BAR binds e.g. "Any+shift" for selectbox actions).
	local MODKEY_TO_KEY = {
		lshift = "shift", rshift = "shift",
		lctrl = "ctrl", rctrl = "ctrl",
		lalt = "alt", ralt = "alt",
		lgui = "meta", rgui = "meta", lmeta = "meta", rmeta = "meta",
		lsuper = "meta", rsuper = "meta",
	}

	-- Pretty names for display() of bare keys.
	local DISPLAY_NAMES = {
		space = "Space", escape = "Esc", ["return"] = "Enter", tab = "Tab",
		backspace = "Backspace", delete = "Del", insert = "Ins",
		home = "Home", ["end"] = "End", pageup = "PgUp", pagedown = "PgDn",
		up = "Up", down = "Down", left = "Left", right = "Right",
		shift = "Shift", ctrl = "Ctrl", alt = "Alt", meta = "Meta",
	}

	local function trim(s)
		return (s:gsub("^%s+", ""):gsub("%s+$", ""))
	end

	-- Split on a single-char separator, keeping empty segments.
	local function split(s, sep)
		local parts = {}
		local start = 1
		while true do
			local i = s:find(sep, start, true)
			if not i then
				parts[#parts + 1] = s:sub(start)
				break
			end
			parts[#parts + 1] = s:sub(start, i - 1)
			start = i + 1
		end
		return parts
	end

	local function parsePress(str)
		local segs = split(str, "+")
		local key
		local modCount
		if #segs == 1 then
			key = segs[1]
			modCount = 0
		elseif segs[#segs] == "" then
			-- Trailing '+': the key itself ends in '+' ("numpad+", bare "+").
			key = segs[#segs - 1] .. "+"
			modCount = #segs - 2
		else
			-- Last segment is the key, even if it names a modifier ("Any+shift").
			key = segs[#segs]
			modCount = #segs - 1
		end

		key = trim(key):lower()

		local mods = {}
		for i = 1, modCount do
			local m = trim(segs[i]):lower()
			if not IS_MOD[m] then
				return nil, "unknown modifier '" .. segs[i] .. "' in press '" .. str .. "'"
			end
			mods[m] = true
		end

		return { mods = mods, key = key }
	end

	---Parse a keyset string. Returns Keyset or nil, error.
	function M.parse(str)
		if type(str) ~= "string" then
			return nil, "keyset must be a string"
		end
		local trimmed = trim(str)
		if trimmed == "" then
			return nil, "empty keyset"
		end

		local presses = {}
		for _, part in ipairs(split(trimmed, ",")) do
			local pressStr = trim(part)
			if pressStr == "" then
				return nil, "empty press in keychain '" .. str .. "' (a literal ',' key is not supported)"
			end
			local press, err = parsePress(pressStr)
			if not press then
				return nil, err
			end
			presses[#presses + 1] = press
		end

		return { presses = presses }
	end

	local function canonicalKey(key)
		return KEY_ALIASES[key] or key
	end

	---Canonical string form: THE identity used for equality and indexing.
	function M.canonical(ks)
		local parts = {}
		for _, p in ipairs(ks.presses) do
			local segs = {}
			for _, m in ipairs(MOD_ORDER) do
				if p.mods[m] then
					segs[#segs + 1] = m
				end
			end
			segs[#segs + 1] = canonicalKey(p.key)
			parts[#parts + 1] = table.concat(segs, "+")
		end
		return table.concat(parts, ",")
	end

	---Emission form for bind/unbind commands (TitleCase mods for readability;
	---the engine is case-insensitive). Keys are emitted as parsed, aliases
	---untouched.
	function M.toEngine(ks)
		local parts = {}
		for _, p in ipairs(ks.presses) do
			local segs = {}
			for _, m in ipairs(MOD_ORDER) do
				if p.mods[m] then
					segs[#segs + 1] = MOD_TITLE[m]
				end
			end
			segs[#segs + 1] = p.key
			parts[#parts + 1] = table.concat(segs, "+")
		end
		return table.concat(parts, ",")
	end

	function M.equals(a, b)
		return M.canonical(a) == M.canonical(b)
	end

	local function copyWith(ks, fn)
		local presses = {}
		for i, p in ipairs(ks.presses) do
			local mods = {}
			for m in pairs(p.mods) do
				mods[m] = true
			end
			presses[i] = { mods = mods, key = p.key }
			fn(presses[i])
		end
		return { presses = presses }
	end

	---New keyset with Shift added to EVERY press (chain companions shift all
	---presses: "sc_b,sc_b" -> "Shift+sc_b,Shift+sc_b").
	function M.withShift(ks)
		return copyWith(ks, function(p) p.mods.shift = true end)
	end

	function M.stripShift(ks)
		return copyWith(ks, function(p) p.mods.shift = nil end)
	end

	function M.withAny(ks)
		return copyWith(ks, function(p) p.mods.any = true end)
	end

	function M.stripAny(ks)
		return copyWith(ks, function(p) p.mods.any = nil end)
	end

	---True if ANY press carries Shift.
	function M.hasShift(ks)
		for _, p in ipairs(ks.presses) do
			if p.mods.shift then
				return true
			end
		end
		return false
	end

	function M.hasAny(ks)
		for _, p in ipairs(ks.presses) do
			if p.mods.any then
				return true
			end
		end
		return false
	end

	---True if any press carries any modifier at all.
	function M.hasMods(ks)
		for _, p in ipairs(ks.presses) do
			if next(p.mods) ~= nil then
				return true
			end
		end
		return false
	end

	local function modsOverlap(a, b)
		if a.any or b.any then
			return true
		end
		for _, m in ipairs(MOD_ORDER) do
			if (a[m] or false) ~= (b[m] or false) then
				return false
			end
		end
		return true
	end

	---Whether two keysets can both fire on the same input. Same chain length,
	---same keys, and per-press modifiers equal or wildcarded by Any. Chain
	---prefix relations ("sc_l" vs "sc_l,sc_l") are deliberate BAR idiom and do
	---NOT count as overlap.
	function M.overlaps(a, b)
		if #a.presses ~= #b.presses then
			return false
		end
		for i = 1, #a.presses do
			local pa, pb = a.presses[i], b.presses[i]
			if canonicalKey(pa.key) ~= canonicalKey(pb.key) then
				return false
			end
			if not modsOverlap(pa.mods, pb.mods) then
				return false
			end
		end
		return true
	end

	---The comma-joined canonical KEY sequence, modifiers stripped. Two keysets
	---can only overlap if their signatures match — used to bucket conflict
	---scans.
	function M.signature(ks)
		local keys = {}
		for i, p in ipairs(ks.presses) do
			keys[i] = canonicalKey(p.key)
		end
		return table.concat(keys, ",")
	end

	local function displayKey(key, scToChar)
		if key:sub(1, 3) == "sc_" then
			local rest = key:sub(4)
			if scToChar then
				rest = scToChar(rest) or rest
			end
			if #rest == 1 then
				return rest:upper()
			end
			return DISPLAY_NAMES[rest] or (rest:sub(1, 1):upper() .. rest:sub(2))
		end
		if #key == 1 then
			return key:upper()
		end
		if key:match("^f%d+$") then
			return key:upper()
		end
		if key:sub(1, 6) == "numpad" then
			return "Num " .. key:sub(7)
		end
		return DISPLAY_NAMES[canonicalKey(key)] or (key:sub(1, 1):upper() .. key:sub(2))
	end

	---Human-readable form for the UI. `scToChar` optionally maps a scancode
	---name ("a", ";") to the character at that position in the user's layout.
	---Chains join with ", ". The Any modifier is shown (user-chosen keysets
	---never carry it; it only appears when displaying foreign binds).
	function M.display(ks, scToChar)
		local parts = {}
		for _, p in ipairs(ks.presses) do
			local segs = {}
			for _, m in ipairs(MOD_ORDER) do
				if p.mods[m] then
					segs[#segs + 1] = MOD_TITLE[m]
				end
			end
			segs[#segs + 1] = displayKey(p.key, scToChar)
			parts[#parts + 1] = table.concat(segs, "+")
		end
		return table.concat(parts, ", ")
	end

	---Build a single-press keyset from raw capture data.
	---  press = { keySymbol = string?, scanSymbol = string?,
	---            alt = bool?, ctrl = bool?, shift = bool?, meta = bool? }
	---Returns Keyset or nil, reason. Policy: named/position-invariant keys use
	---the key symbol; layout-position keys (letters, punctuation) use the
	---scancode (sc_*) so binds survive layout switches.
	function M.fromCapture(press)
		local keySym = press.keySymbol and trim(press.keySymbol):lower() or ""
		local scanSym = press.scanSymbol and trim(press.scanSymbol):lower() or ""

		local mods = {}
		if press.alt then mods.alt = true end
		if press.ctrl then mods.ctrl = true end
		if press.shift then mods.shift = true end
		if press.meta then mods.meta = true end

		local key
		local modAsKey = MODKEY_TO_KEY[keySym]
		if not modAsKey and IS_MOD[keySym] then
			modAsKey = keySym
		end
		if modAsKey then
			-- A bare modifier bound as the key itself ("Any+shift"): the
			-- pressed modifier is the key, not one of its own mods.
			key = modAsKey
			mods[modAsKey] = nil
		elseif keySym ~= "" and (INVARIANT_KEYS[keySym] or keySym:match("^f%d+$") or keySym:sub(1, 6) == "numpad") then
			key = keySym
		elseif scanSym ~= "" then
			-- Spring.GetScanSymbol already returns the "sc_"-prefixed form
			-- (e.g. "sc_a"); don't prefix it a second time.
			key = scanSym:sub(1, 3) == "sc_" and scanSym or ("sc_" .. scanSym)
		elseif keySym ~= "" then
			key = keySym
		else
			return nil, "unrecognized key"
		end

		return { presses = { { mods = mods, key = key } } }
	end

	---If `keySymbol` names a modifier key (shift/ctrl/alt/meta, incl. the
	---left/right physical variants), return its canonical bare-modifier name;
	---otherwise nil. Capture uses this to tell a modifier-only press apart
	---from a real key press. "any" is intentionally excluded — it is never a
	---physical key.
	function M.modifierKeyName(keySymbol)
		local sym = keySymbol and trim(tostring(keySymbol)):lower() or ""
		if sym == "" then
			return nil
		end
		local mapped = MODKEY_TO_KEY[sym]
		if mapped then
			return mapped
		end
		if sym ~= "any" and IS_MOD[sym] then
			return sym
		end
		return nil
	end

	---Append a press (table from fromCapture, single press) to an existing
	---keyset, forming a chain. Returns a NEW keyset.
	function M.appendPress(ks, single)
		local presses = {}
		for i, p in ipairs(ks.presses) do
			presses[i] = p
		end
		presses[#presses + 1] = single.presses[1]
		return { presses = presses }
	end

	return M
end
