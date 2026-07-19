-- capture.lua state machine + the slot-edit apply semantics the widget's
-- onCaptureCommit implements on top of the model.

return function(core, t, fixture, ctx)
	local Capture = ctx.requireRuntime("capture.lua")
	local K = core.keyset

	-- Synthetic keyboard: keyCode -> { key = keySymbol, scan = scanSymbol }.
	-- Spring.GetScanSymbol returns the "sc_"-prefixed form already (e.g.
	-- "sc_a"), so fixtures mirror that instead of bare letters.
	local KEYS = {
		[65] = { key = "a", scan = "sc_a" },
		[66] = { key = "b", scan = "sc_b" },
		[88] = { key = "x", scan = "sc_x" },
		[80] = { key = "p", scan = "sc_p" },
		[32] = { key = "space", scan = "sc_space" },
		[304] = { key = "lshift", scan = "sc_lshift" }, -- modifier key
		[306] = { key = "lctrl", scan = "sc_lctrl" },
		[292] = { key = "f9", scan = "sc_f9" }, -- invariant key (standalone stays bare "f9")
	}

	local function makeCapture(meta)
		local committed, cancelled = {}, {}
		local cap = Capture.new({
			keyset = K,
			getKeySymbol = function(c) return KEYS[c] and KEYS[c].key end,
			getScanSymbol = function(c) return KEYS[c] and KEYS[c].scan end,
			getMeta = function() return meta or false end,
			chainTimeout = 0.7,
			onCommit = function(uid, slot, ks)
				committed[#committed + 1] = { uid = uid, slot = slot, ks = ks }
			end,
			onCancel = function(uid, slot)
				cancelled[#cancelled + 1] = { uid = uid, slot = slot }
			end,
		})
		return cap, committed, cancelled
	end

	----------------------------------------------------------------
	-- Single combo, auto-commit on chain-window expiry
	----------------------------------------------------------------
	local cap, committed = makeCapture()
	cap:begin({ unitId = "attack", slot = 1, actionLabel = "Attack" })
	t.ok(cap:isActive(), "active after begin")
	cap:keyPress(88, { ctrl = true }, false, 88) -- Ctrl+X
	t.eq(cap:pendingCanonical(), "ctrl+sc_x", "pending combo built from mods + scancode")
	t.count(committed, "not committed before window expiry", 0)
	cap:update(0.8)
	t.count(committed, "committed after window", 1)
	t.eq(committed[1].ks, "ctrl+sc_x", "committed canonical keyset")
	t.eq(committed[1].slot, 1, "slot carried through")
	t.ok(not cap:isActive(), "inactive after commit")

	----------------------------------------------------------------
	-- Chain: second press within window extends
	----------------------------------------------------------------
	cap, committed = makeCapture()
	cap:begin({ unitId = "onoff_off", slot = 1 })
	cap:keyPress(66, {}, false, 66)
	cap:update(0.3) -- inside window
	cap:keyPress(66, {}, false, 66)
	t.eq(cap:pendingCanonical(), "sc_b,sc_b", "second press within window forms a chain")
	t.count(committed, "chain not committed while window open", 0)
	cap:update(0.8)
	t.eq(committed[1].ks, "sc_b,sc_b", "chain committed after window")

	----------------------------------------------------------------
	-- Chain of an invariant/named key (F9): the engine rejects chaining
	-- this class of key entirely, in every string form ("f9,f9" AND
	-- "sc_f9,sc_f9" both error "Bad keysym" live). Capture must refuse to
	-- form the chain rather than guess at a representation, leaving the
	-- original single press intact so it can still commit alone.
	----------------------------------------------------------------
	cap, committed = makeCapture()
	cap:begin({ unitId = "group_focus/0", slot = 1 })
	cap:keyPress(292, {}, false, 292)
	t.eq(cap:pendingCanonical(), "f9", "single F9 press stays bare symbol")
	cap:keyPress(292, {}, false, 292)
	t.eq(cap:pendingCanonical(), "f9", "second F9 press is refused as a chain, pending unchanged")
	t.ok(cap.message ~= nil, "refused chain sets a feedback message")
	cap:update(0.8)
	t.eq(committed[1].ks, "f9", "original single F9 press still commits normally")

	----------------------------------------------------------------
	-- Accept button commits immediately
	----------------------------------------------------------------
	cap, committed = makeCapture()
	cap:begin({ unitId = "attack", slot = 2 })
	cap:keyPress(88, {}, false, 88)
	cap:accept()
	t.eq(committed[1].ks, "sc_x", "accept commits pending immediately")
	t.eq(committed[1].slot, 2, "accept keeps slot")

	----------------------------------------------------------------
	-- Modifier-only binding: commit on release with nothing else pressed
	----------------------------------------------------------------
	cap, committed = makeCapture()
	cap:begin({ unitId = "selectbox_append", slot = 1 })
	cap:keyPress(304, { shift = true }, false, 304) -- Shift alone
	t.eq(cap:pendingCanonical(), nil, "modifier alone does not build a combo")
	t.count(committed, "modifier alone does not commit", 0)
	cap:keyRelease(304, {}, 304)
	t.eq(committed[1].ks, "shift", "bare modifier committed on release")

	-- A real key in between cancels the bare-modifier path
	cap, committed = makeCapture()
	cap:begin({ unitId = "selectbox_append", slot = 1 })
	cap:keyPress(304, { shift = true }, false, 304)
	cap:keyPress(88, { shift = true }, false, 88)
	cap:keyRelease(304, {}, 304)
	t.count(committed, "release after a real key does not bare-commit", 0)
	cap:update(0.8)
	t.eq(committed[1].ks, "shift+sc_x", "real key with held modifier commits normally")

	----------------------------------------------------------------
	-- Cancel + unbind + repeat handling + meta
	----------------------------------------------------------------
	local cancelled
	cap, committed, cancelled = makeCapture()
	cap:begin({ unitId = "attack", slot = 2 })
	cap:keyPress(88, {}, false, 88)
	cap:cancel()
	t.count(committed, "cancel does not commit", 0)
	t.count(cancelled, "cancel fires onCancel", 1)
	t.ok(not cap:isActive(), "inactive after cancel")

	cap, committed = makeCapture()
	cap:begin({ unitId = "attack", slot = 1 })
	cap:unbind()
	t.count(committed, "unbind commits once", 1)
	t.eq(committed[1].ks, nil, "unbind commits a nil keyset")
	t.eq(committed[1].slot, 1, "unbind carries slot")

	cap, committed = makeCapture()
	cap:begin({ unitId = "attack", slot = 1 })
	cap:keyPress(88, {}, true, 88) -- isRepeat
	t.eq(cap:pendingCanonical(), nil, "auto-repeat presses are ignored")

	cap, committed = makeCapture(true) -- meta held
	cap:begin({ unitId = "attack", slot = 1 })
	cap:keyPress(88, {}, false, 88)
	t.eq(cap:pendingCanonical(), "meta+sc_x", "meta pulled from getMeta injection")

	----------------------------------------------------------------
	-- Slot-edit apply semantics (mirror of widget onCaptureCommit)
	----------------------------------------------------------------
	local function newModel()
		local m = core.model.new({
			catalogTable = fixture.catalogTable,
			presetKey = "grid",
			persistedOverrides = nil,
		})
		m.refreshFromSnapshot(fixture.binds)
		return m
	end

	local function slotEdit(m, unitId, slot, ks)
		local current = m.effectiveKeysets(unitId) or {}
		local newList = {}
		for i, c in ipairs(current) do
			newList[i] = c
		end
		if ks == nil then
			if slot <= #newList then
				table.remove(newList, slot)
			end
		else
			newList[slot] = ks
		end
		return m.setBinding(unitId, newList)
	end

	local m = newModel()
	t.eq(m.effectiveKeysets("attack"), { "sc_a", "sc_x" }, "effectiveKeysets returns display-ordered canonicals")

	-- Replace primary slot: full auto_shift shape re-emitted for the new key.
	local plan = slotEdit(m, "attack", 1, "sc_p")
	t.ok(plan ~= nil, "primary slot replace plans")
	local hasCompanion = false
	for _, c in ipairs(plan.commands) do
		if c == "bind Shift+sc_p attack" then
			hasCompanion = true
		end
	end
	t.ok(hasCompanion, "auto_shift companion generated for the new primary key")

	-- Add to the empty secondary slot of a single-bound unit.
	m = newModel()
	t.eq(m.effectiveKeysets("areaattack"), { "ctrl+sc_a" }, "areaattack has one base keyset")
	plan = slotEdit(m, "areaattack", 2, "sc_m")
	t.ok(plan ~= nil, "adding to empty slot plans")
	local addsSecond = false
	for _, c in ipairs(plan.commands) do
		if c == "bind sc_m areaattack" then
			addsSecond = true
		end
	end
	t.ok(addsSecond, "second binding added without disturbing the first")

	-- Unbind the secondary slot.
	m = newModel()
	plan = slotEdit(m, "attack", 2, nil)
	t.ok(plan ~= nil, "unbinding a slot plans")
	local removesX = false
	for _, c in ipairs(plan.commands) do
		if c == "unbind sc_x attack" then
			removesX = true
		end
	end
	t.ok(removesX, "unbinding slot 2 removes exactly that keyset")

	-- Validation error surfaces to the caller (widget reopens with message).
	m = newModel()
	local badPlan, err = slotEdit(m, "attack", 1, "shift+sc_p")
	t.ok(badPlan == nil and err ~= nil, "Shift on auto_shift rejected through the slot edit")
end
