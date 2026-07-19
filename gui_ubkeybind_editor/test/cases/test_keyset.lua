-- keyset.lua: parsing, canonical identity, transforms, overlap, capture.

return function(core, t)
	local K = core.keyset

	local function canonOf(str)
		local ks, err = K.parse(str)
		if not ks then
			return nil, err
		end
		return K.canonical(ks)
	end

	-- Parsing + canonical form
	t.eq(canonOf("Alt+ctrl+sc_a"), "alt+ctrl+sc_a", "mixed-case mods normalize in fixed order")
	t.eq(canonOf("shift+ctrl+sc_a"), "ctrl+shift+sc_a", "modifier order is any,alt,ctrl,meta,shift")
	t.eq(canonOf("Alt+numpad+"), "alt+numpad+", "keys ending in '+' parse (numpad+)")
	t.eq(canonOf("Any+shift"), "any+shift", "modifier name as the key (Any+shift)")
	t.eq(canonOf("+"), "+", "bare '+' key parses")
	t.eq(canonOf("Ctrl++"), "ctrl++", "modified '+' key parses")
	t.eq(canonOf("Shift+sc_b,Shift+sc_b"), "shift+sc_b,shift+sc_b", "chains keep per-press mods")
	t.eq(canonOf("Ctrl+esc"), canonOf("ctrl+escape"), "esc/escape alias equality")
	t.eq(canonOf("meta+alt+0"), "alt+meta+0", "meta modifier accepted")

	-- Parse failures
	t.ok(not K.parse(""), "empty keyset rejected")
	t.ok(not K.parse("foo+a"), "unknown modifier rejected")
	t.ok(not K.parse("sc_b,,sc_b"), "empty chain press rejected")
	t.ok(not K.parse(nil), "non-string rejected")

	-- toEngine emission (TitleCase, aliases untouched)
	local ks = K.parse("shift+ctrl+sc_a")
	t.eq(K.toEngine(ks), "Ctrl+Shift+sc_a", "toEngine uses fixed TitleCase order")
	t.eq(K.toEngine(K.parse("ctrl+esc")), "Ctrl+esc", "toEngine keeps the alias as given")

	-- withShift shifts EVERY press of a chain
	local chain = K.parse("sc_b,sc_b")
	t.eq(K.canonical(K.withShift(chain)), "shift+sc_b,shift+sc_b", "withShift maps over all presses")
	t.ok(not K.hasShift(chain), "hasShift false on plain chain")
	t.ok(K.hasShift(K.withShift(chain)), "hasShift true after withShift")
	t.eq(K.canonical(K.stripShift(K.withShift(chain))), "sc_b,sc_b", "stripShift undoes withShift")

	-- Any transforms
	local sp = K.parse("space")
	t.eq(K.canonical(K.withAny(sp)), "any+space", "withAny")
	t.eq(K.canonical(K.stripAny(K.withAny(sp))), "space", "stripAny")
	t.ok(K.hasMods(K.parse("ctrl+sc_a")), "hasMods true with ctrl")
	t.ok(not K.hasMods(sp), "hasMods false when bare")

	-- Round-trip: parse(canonical(x)) == x
	for _, s in ipairs({ "Alt+ctrl+sc_a", "Any+shift", "Alt+numpad+", "Shift+sc_b,Shift+sc_b", "Ctrl+esc" }) do
		t.eq(canonOf(select(1, K.canonical(K.parse(s)))), canonOf(s), "canonical round-trips: " .. s)
	end

	-- Overlap semantics
	local function overlaps(a, b)
		return K.overlaps(K.parse(a), K.parse(b))
	end
	t.ok(overlaps("Any+sc_k", "Ctrl+sc_k"), "Any wildcards modifiers")
	t.ok(overlaps("Any+sc_k", "sc_k"), "Any overlaps bare")
	t.ok(not overlaps("Ctrl+sc_k", "sc_k"), "different mods do not overlap")
	t.ok(not overlaps("sc_l", "sc_l,sc_l"), "chain prefix is NOT overlap (firestate idiom)")
	t.ok(not overlaps("shift+sc_b,shift+sc_b", "sc_b,sc_b"), "shifted chain vs plain chain: no overlap")
	t.ok(overlaps("any+sc_b,any+sc_b", "shift+sc_b,shift+sc_b"), "Any chain wildcards each press")
	t.ok(overlaps("ctrl+esc", "ctrl+escape"), "overlap respects aliases")

	-- Signature (bucket key for conflict scans)
	t.eq(K.signature(K.parse("Ctrl+sc_b,Shift+sc_b")), "sc_b,sc_b", "signature strips mods")
	t.eq(K.signature(K.parse("Ctrl+esc")), "escape", "signature applies aliases")

	-- Display
	t.eq(K.display(K.parse("ctrl+shift+sc_a")), "Ctrl+Shift+A", "display: mods + scancode letter")
	t.eq(K.display(K.parse("sc_b,sc_b")), "B, B", "display: chain")
	t.eq(K.display(K.parse("space")), "Space", "display: named key")
	t.eq(K.display(K.parse("numpad8")), "Num 8", "display: numpad")
	t.eq(K.display(K.parse("f3")), "F3", "display: function key")
	t.eq(K.display(K.parse("sc_a"), function(c) return c == "a" and "q" or nil end), "Q",
		"display: layout map translates scancode position")

	-- Capture
	local function cap(press)
		local kset, err = K.fromCapture(press)
		if not kset then
			return nil, err
		end
		return K.canonical(kset)
	end
	t.eq(cap({ keySymbol = "a", scanSymbol = "a", ctrl = true }), "ctrl+sc_a",
		"capture prefers scancode for letters")
	t.eq(cap({ keySymbol = "space", scanSymbol = "space" }), "space",
		"capture uses key symbol for invariant keys")
	t.eq(cap({ keySymbol = "f3", scanSymbol = "3" }), "f3", "capture: function keys invariant")
	t.eq(cap({ keySymbol = "numpad8", scanSymbol = "kp_8" }), "numpad8", "capture: numpad invariant")
	t.eq(cap({ keySymbol = "lshift", shift = true }), "shift",
		"capture: bare modifier becomes the key, not its own mod")
	t.eq(cap({ keySymbol = "x", scanSymbol = "x", alt = true, meta = true }), "alt+meta+sc_x",
		"capture: meta flag honored")
	t.ok(not K.fromCapture({}), "capture with no symbols rejected")

	-- Chain building
	local first = K.fromCapture({ keySymbol = "b", scanSymbol = "b" })
	local second = K.fromCapture({ keySymbol = "b", scanSymbol = "b", shift = true })
	t.eq(K.canonical(K.appendPress(first, second)), "sc_b,shift+sc_b", "appendPress builds chains")

	-- Chains of a named/invariant key (function keys, space, numpad...) are
	-- fine to CREATE — the engine's `bind` command splits on commas and
	-- parses each press independently (ParseKeyChain), so any key that
	-- parses standalone also chains fine. The real constraint (confirmed
	-- against the engine source) is that `unbind` can never remove ANY
	-- chain, regardless of which keys are in it — that's handled at the
	-- engine_sync layer (a doomed unbind is redirected through a pristine
	-- reload instead), not by restricting what capture can build.
	local f9a = K.fromCapture({ keySymbol = "f9", scanSymbol = "f9" })
	local f9b = K.fromCapture({ keySymbol = "f9", scanSymbol = "f9" })
	t.eq(K.canonical(K.appendPress(f9a, f9b)), "f9,f9", "function keys chain fine (bind supports it)")
end
