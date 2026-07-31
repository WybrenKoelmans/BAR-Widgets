-- conflicts.lua: managed scans stay quiet on base noise, probes see
-- everything, companion collisions are attributed.

return function(core, t, fixture)
	local function newModel()
		local m = core.model.new({
			catalogTable = fixture.catalogTable,
			presetKey = "luaui/configs/hotkeys/grid_keys.txt",
			persistedOverrides = nil,
		})
		m.refreshFromSnapshot(fixture.binds)
		return m
	end

	----------------------------------------------------------------
	-- Base state: no managed conflicts, despite the esc stack and the
	-- buildunit pile (unmanaged noise must stay silent in scan()).
	----------------------------------------------------------------
	local m = newModel()
	t.count(m.allConflicts(), "pristine base scans clean", 0)

	----------------------------------------------------------------
	-- Companion collision: areaattack -> Ctrl+esc makes its implicit
	-- Shift companion land on quitforce's Ctrl+Shift+esc.
	----------------------------------------------------------------
	m = newModel()
	local plan = m.setBinding("areaattack", { "ctrl+esc" })
	t.ok(plan ~= nil, "areaattack rebind plans")
	m.commitPlan(plan)

	local conflicts = m.allConflicts()
	local hit = t.contains(conflicts, function(c)
		return c.keyset == "ctrl+shift+escape"
	end, "companion collision detected at ctrl+shift+escape")
	if hit then
		local sources = { [hit.a.source] = hit.a, [hit.b.source] = hit.b }
		t.ok(sources.companion ~= nil and sources.companion.unitId == "areaattack",
			"collision attributed to areaattack's companion")
		t.ok(sources.user ~= nil and sources.user.unitId == "quitforce",
			"collision names quitforce's own keyset")
	end

	----------------------------------------------------------------
	-- Probe warns BEFORE committing (capture-time feedback)
	----------------------------------------------------------------
	m = newModel()
	local hits = m.probeConflicts("areaattack", "ctrl+esc")
	t.contains(hits, function(h) return h.unitId == "quitforce" and h.via == "ctrl+shift+escape" end,
		"probe predicts the companion collision")

	-- Probe consults the unmanaged pool (buildunit stack on sc_z)
	hits = m.probeConflicts("teamstatus_close", "sc_z")
	t.contains(hits, function(h) return h.action == "buildunit_armmex" and h.source == "unmanaged" end,
		"probe reports unmanaged occupants of sc_z")

	-- Probe understands Any wildcarding: attack onto wantcloak's key
	hits = m.probeConflicts("attack", "sc_k")
	t.contains(hits, function(h) return h.unitId == "wantcloak" end,
		"probe sees Any+sc_k shadowing a plain sc_k candidate")

	-- Probing the unit's own keyset does not self-report
	hits = m.probeConflicts("attack", "sc_a")
	t.count(hits, "no self-conflicts", 0)

	-- Chain prefixes never conflict (firestate idiom)
	hits = m.probeConflicts("teamstatus_close", "sc_l,sc_l")
	local firestateHits = 0
	for _, h in ipairs(hits) do
		if h.unitId == "firestate/2" or h.unitId == "firestate/1" then
			firestateHits = firestateHits + 1
		end
	end
	t.eq(firestateHits, 0, "chain-prefix family members do not cross-conflict")
	t.contains(hits, function(h) return h.unitId == "firestate/0" end,
		"exact chain-length match does conflict")

	----------------------------------------------------------------
	-- Probe validation errors
	----------------------------------------------------------------
	local res, err = m.probeConflicts("attack", "not a + keyset,,")
	t.ok(res == nil and err ~= nil, "probe rejects unparseable keysets")

	local ok2, reason = m.validateBinding("attack", "shift+sc_a")
	t.ok(not ok2 and reason ~= nil, "validateBinding surfaces processor rules")
	t.ok(select(1, m.validateBinding("attack", "ctrl+sc_a")), "validateBinding accepts good keysets")
end
