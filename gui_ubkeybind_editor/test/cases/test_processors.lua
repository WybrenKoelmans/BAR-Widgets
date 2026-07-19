-- processors.lua: shape closure laws, matching, drift, validation.

return function(core, t)
	local K = core.keyset
	local P = core.processors

	local function pool(entries)
		local out = {}
		for _, e in ipairs(entries) do
			out[#out + 1] = { ks = K.parse(e[1]), action = e[2] }
		end
		return out
	end

	local function canonList(keysets)
		local out = {}
		for i, ks in ipairs(keysets) do
			out[i] = K.canonical(ks)
		end
		return out
	end

	local function canonPairs(prs)
		local out = {}
		for i, pr in ipairs(prs) do
			out[i] = K.canonical(pr.ks) .. " " .. pr.action
		end
		return out
	end

	local function driftKinds(drift)
		local out = {}
		for _, d in ipairs(drift) do
			out[#out + 1] = d.kind
		end
		table.sort(out)
		return out
	end

	----------------------------------------------------------------
	-- Closure law: fromEngine(toEngine(ks)) == ks, no drift
	----------------------------------------------------------------
	local closureCases = {
		{ type = "direct", def = { action = "toggleoverview" }, keysets = { "sc_o", "ctrl+sc_o" } },
		{ type = "auto_shift", def = { action = "attack" }, keysets = { "sc_a", "ctrl+sc_d" } },
		{ type = "auto_shift", def = { action = "onoff 0" }, keysets = { "sc_b,sc_b" } },
		{ type = "queued_pair", def = { actions = { "selfd", "selfd queued" } }, keysets = { "ctrl+sc_b" } },
		{ type = "any_wrap", def = { action = "buildsplit" }, keysets = { "space" } },
	}
	for _, c in ipairs(closureCases) do
		local proc = P.get(c.type)
		local input = {}
		for i, s in ipairs(c.keysets) do
			input[i] = K.parse(s)
		end
		local engine = proc.toEngine(c.def, input)
		local back, consumed, drift = proc.fromEngine(c.def, engine)
		t.eq(canonList(back), canonList(input), c.type .. " closure: keysets survive round-trip")
		t.count(drift, c.type .. " closure: no drift", 0)
		local n = 0
		for _ in pairs(consumed) do
			n = n + 1
		end
		t.eq(n, #engine, c.type .. " closure: everything consumed")
	end

	----------------------------------------------------------------
	-- auto_shift specifics
	----------------------------------------------------------------
	local autoShift = P.get("auto_shift")
	local def = { action = "attack" }

	-- toEngine shape: plain + shifted per keyset, chains shift every press
	local eng = autoShift.toEngine({ action = "onoff 0" }, { K.parse("sc_b,sc_b") })
	t.eq(canonPairs(eng), { "sc_b,sc_b onoff 0", "shift+sc_b,shift+sc_b onoff 0" },
		"auto_shift chain companion shifts every press")

	-- Pairing with drift: sc_a paired, sc_x missing its companion
	local ksets, consumed, drift = autoShift.fromEngine(def, pool({
		{ "sc_a", "attack" }, { "Shift+sc_a", "attack" }, { "sc_x", "attack" },
	}))
	t.eq(canonList(ksets), { "sc_a", "sc_x" }, "auto_shift: plain keysets become user keysets")
	t.eq(driftKinds(drift), { "missing_companion" }, "auto_shift: unpaired plain reports missing_companion")
	t.ok(consumed[1] and consumed[2] and consumed[3], "auto_shift: all attack binds consumed")

	-- Orphan shift half: consumed, not a keyset
	ksets, consumed, drift = autoShift.fromEngine(def, pool({ { "Shift+sc_y", "attack" } }))
	t.count(ksets, "auto_shift: orphan shift half yields no keyset", 0)
	t.ok(consumed[1], "auto_shift: orphan shift half still consumed")
	t.eq(driftKinds(drift), { "orphan_companion" }, "auto_shift: orphan drift kind")

	-- Any-modified bind is off-shape: left unconsumed
	ksets, consumed, drift = autoShift.fromEngine(def, pool({ { "Any+sc_k", "attack" } }))
	t.ok(not consumed[1], "auto_shift: Any bind left for foreign_shape absorption")

	-- Validation
	t.ok(not select(1, autoShift.validate(def, K.parse("Shift+sc_a"))), "auto_shift rejects Shift")
	t.ok(not select(1, autoShift.validate(def, K.parse("Any+sc_a"))), "auto_shift rejects Any")
	t.ok(select(1, autoShift.validate(def, K.parse("Ctrl+sc_a"))), "auto_shift accepts Ctrl")

	----------------------------------------------------------------
	-- queued_pair specifics
	----------------------------------------------------------------
	local queued = P.get("queued_pair")
	local qdef = { actions = { "selfd", "selfd queued" } }

	local qeng = queued.toEngine(qdef, { K.parse("alt+sc_b") })
	t.eq(canonPairs(qeng), { "alt+sc_b selfd", "alt+shift+sc_b selfd queued" },
		"queued_pair emits base + shifted queued action")

	ksets, consumed, drift = queued.fromEngine(qdef, pool({
		{ "Ctrl+sc_b", "selfd" }, { "Ctrl+Shift+sc_b", "selfd queued" },
	}))
	t.eq(canonList(ksets), { "ctrl+sc_b" }, "queued_pair: one user keyset from the pair")
	t.count(drift, "queued_pair: clean pair has no drift", 0)

	-- Queued variant bound elsewhere: orphan, consumed
	ksets, consumed, drift = queued.fromEngine(qdef, pool({
		{ "Ctrl+sc_b", "selfd" }, { "Alt+sc_n", "selfd queued" },
	}))
	t.eq(canonList(ksets), { "ctrl+sc_b" }, "queued_pair: mislocated queued does not add a keyset")
	t.eq(driftKinds(drift), { "missing_companion", "orphan_companion" },
		"queued_pair: mislocated queued -> missing + orphan drift")
	t.ok(consumed[2], "queued_pair: mislocated queued still consumed")

	t.ok(not select(1, queued.validate(qdef, K.parse("Shift+sc_b"))), "queued_pair rejects Shift")

	----------------------------------------------------------------
	-- any_wrap specifics
	----------------------------------------------------------------
	local anyWrap = P.get("any_wrap")
	local adef = { action = "wantcloak" }

	-- Double-bind: Any form + redundant plain, both consumed, one keyset
	for _, order in ipairs({
		{ { "sc_k", "wantcloak" }, { "Any+sc_k", "wantcloak" } },
		{ { "Any+sc_k", "wantcloak" }, { "sc_k", "wantcloak" } },
	}) do
		ksets, consumed, drift = anyWrap.fromEngine(adef, pool(order))
		t.eq(canonList(ksets), { "sc_k" }, "any_wrap: double-bind collapses to one keyset (either order)")
		t.ok(consumed[1] and consumed[2], "any_wrap: both binds consumed")
		t.eq(driftKinds(drift), { "redundant_plain" }, "any_wrap: plain duplicate flagged")
	end

	-- Plain-only: still a keyset, wrapped on first edit
	ksets, consumed, drift = anyWrap.fromEngine(adef, pool({ { "sc_j", "wantcloak" } }))
	t.eq(canonList(ksets), { "sc_j" }, "any_wrap: plain-only bind becomes a keyset")
	t.eq(driftKinds(drift), { "missing_any_wrap" }, "any_wrap: plain-only flagged")

	-- Any with extra modifiers: off-shape
	ksets, consumed, drift = anyWrap.fromEngine(adef, pool({ { "Any+Ctrl+sc_k", "wantcloak" } }))
	t.ok(not consumed[1], "any_wrap: Any+Ctrl left for foreign_shape absorption")

	t.ok(not select(1, anyWrap.validate(adef, K.parse("Ctrl+sc_k"))), "any_wrap rejects modifiers")
	t.ok(select(1, anyWrap.validate(adef, K.parse("sc_k,sc_k"))), "any_wrap accepts bare chains")

	----------------------------------------------------------------
	-- occupies
	----------------------------------------------------------------
	local occ = autoShift.occupies(def, { K.parse("ctrl+sc_a") })
	t.eq(canonPairs(occ), { "ctrl+sc_a attack", "ctrl+shift+sc_a attack" },
		"auto_shift occupies user + companion footprint")
	t.eq(occ[2].source, "companion", "companion footprint tagged")

	occ = anyWrap.occupies(adef, { K.parse("sc_k") })
	t.eq(canonList({ occ[1].ks }), { "any+sc_k" }, "any_wrap occupies the wrapped keyset")
	t.eq(occ[1].source, "any_wrap", "any_wrap footprint tagged")
end
