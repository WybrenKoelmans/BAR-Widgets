-- compile.lua + model.lua: no-op round-trip, edit plans, resets, keyset
-- rebuild ordering, verification, watchdog diff/absorb.

return function(core, t, fixture)
	local function newModel()
		local m = core.model.new({
			catalogTable = fixture.catalogTable,
			presetKey = "luaui/configs/hotkeys/grid_keys.txt",
			persistedOverrides = nil,
		})
		local plan = m.refreshFromSnapshot(fixture.binds)
		return m, plan
	end

	----------------------------------------------------------------
	-- THE round-trip guarantee: import then compile emits nothing
	----------------------------------------------------------------
	local m, startupPlan = newModel()
	t.count(startupPlan.commands, "empty store: startup plan is a no-op", 0)

	----------------------------------------------------------------
	-- any_wrap edit: cleans redundancy, wraps the new key
	----------------------------------------------------------------
	m = newModel()
	local plan, err = m.setBinding("wantcloak", { "sc_j" })
	t.ok(plan ~= nil, "wantcloak rebind produces a plan" .. (err and (": " .. err) or ""))
	t.eq(plan.commands, {
		"unbind sc_k wantcloak",
		"unbind Any+sc_k wantcloak",
		"bind Any+sc_j wantcloak",
	}, "wantcloak: both old binds removed (verbatim keysets), new one wrapped")

	----------------------------------------------------------------
	-- queued_pair edit: both actions move together
	----------------------------------------------------------------
	m = newModel()
	plan = m.setBinding("selfd", { "alt+sc_b" })
	t.eq(plan.commands, {
		"unbind Ctrl+sc_b selfd",
		"unbind Ctrl+Shift+sc_b selfd queued",
		"bind Alt+sc_b selfd",
		"bind Alt+Shift+sc_b selfd queued",
	}, "selfd: base and queued variant move as one")

	----------------------------------------------------------------
	-- Validation surfaces through setBinding
	----------------------------------------------------------------
	m = newModel()
	plan, err = m.setBinding("selfd", { "shift+sc_b" })
	t.ok(plan == nil and err ~= nil, "Shift rejected for queued_pair with a reason")
	plan, err = m.setBinding("force_start", { "sc_q" })
	t.ok(plan == nil and err ~= nil, "locked unit rejects edits")
	plan, err = m.setBinding("buildsplit", { "ctrl+space" })
	t.ok(plan == nil and err ~= nil, "any_wrap rejects modifiers")
	plan, err = m.setBinding("attack", { "f9,f9" })
	t.ok(plan == nil and err ~= nil, "chaining a non-chainable key (bare symbol) is rejected")
	plan, err = m.setBinding("attack", { "sc_f9,sc_f9" })
	t.ok(plan == nil and err ~= nil, "chaining a non-chainable key (scancode form) is rejected too")

	----------------------------------------------------------------
	-- Same-as-base set clears instead of storing (no commands)
	----------------------------------------------------------------
	m = newModel()
	plan = m.setBinding("attack", { "sc_a", "sc_x" })
	t.count(plan.commands, "re-entering base keysets is a no-op", 0)
	t.eq(m.overrideCount(), 0, "no override stored for base-equal set")

	----------------------------------------------------------------
	-- Real attack edit: canonicalize-on-write generates the companion
	----------------------------------------------------------------
	m = newModel()
	plan = m.setBinding("attack", { "sc_a" })
	t.eq(plan.commands, { "unbind sc_x attack" },
		"dropping the drifted keyset removes only it (sc_a pair untouched)")

	m = newModel()
	plan = m.setBinding("attack", { "sc_p" })
	t.eq(plan.commands, {
		"unbind sc_a attack",
		"unbind Shift+sc_a attack",
		"unbind sc_x attack",
		"bind sc_p attack",
		"bind Shift+sc_p attack",
	}, "attack rebind: all base pairs out, canonical shape in")

	----------------------------------------------------------------
	-- Unbind entirely
	----------------------------------------------------------------
	m = newModel()
	plan = m.setBinding("attack", {})
	t.count(plan.commands, "unbind-all removes every pair", 3)
	t.eq(m.overrideCount(), 1, "unbound stored as an override")

	----------------------------------------------------------------
	-- Commit + reset restores base VERBATIM (drift included)
	----------------------------------------------------------------
	m = newModel()
	plan = m.setBinding("wantcloak", { "sc_j" })
	m.commitPlan(plan)
	plan = m.resetUnit("wantcloak")
	t.eq(plan.commands, {
		"unbind Any+sc_j wantcloak",
		"bind sc_k wantcloak",
		"bind Any+sc_k wantcloak",
	}, "reset restores base pairs verbatim, redundancy and all")
	m.commitPlan(plan)
	t.eq(m.overrideCount(), 0, "reset clears the override")
	local ok = m.diffLive(fixture.binds)
	t.ok(ok, "after reset, live base matches expectations again")

	----------------------------------------------------------------
	-- esc keyset rebuild: restored pair keeps its base position
	----------------------------------------------------------------
	m = newModel()
	plan = m.setBinding("teamstatus_close", { "sc_p" })
	t.eq(plan.commands, {
		"unbind esc teamstatus_close",
		"bind sc_p teamstatus_close",
	}, "moving one esc action off is surgical")
	m.commitPlan(plan)

	plan = m.resetUnit("teamstatus_close")
	t.eq(plan.commands, {
		"unbind sc_p teamstatus_close",
		"unbind esc select AllMap++_ClearSelection_SelectNum_0+",
		"unbind esc quitmessage",
		"unbind esc customgameinfo_close",
		"unbind esc buildmenu_pregame_deselect",
		"bind esc select AllMap++_ClearSelection_SelectNum_0+",
		"bind esc quitmessage",
		"bind esc teamstatus_close",
		"bind esc customgameinfo_close",
		"bind esc buildmenu_pregame_deselect",
	}, "reset onto a shared keyset rebuilds it in base order")
	m.commitPlan(plan)

	----------------------------------------------------------------
	-- verify: against projected state ok, against stale state not ok
	----------------------------------------------------------------
	m = newModel()
	plan = m.setBinding("selfd", { "alt+sc_b" })
	local okStale = m.verifyPlan(fixture.binds, plan)
	t.ok(not okStale, "verify fails against the unchanged snapshot")

	-- Build the post-apply snapshot from the plan projection
	m.commitPlan(plan)
	local post = {}
	for _, pr in ipairs(fixture.binds) do
		local action = pr.extra ~= "" and (pr.command .. " " .. pr.extra) or pr.command
		action = action:lower()
		if not (action == "selfd" or action == "selfd queued") then
			post[#post + 1] = pr
		end
	end
	post[#post + 1] = { command = "selfd", extra = "", boundWith = "Alt+sc_b" }
	post[#post + 1] = { command = "selfd", extra = "queued", boundWith = "Alt+Shift+sc_b" }
	local okPost = m.verifyPlan(post, plan)
	t.ok(okPost, "verify passes once the batch landed")

	----------------------------------------------------------------
	-- Watchdog diff: ours missing / foreign added / absorb
	----------------------------------------------------------------
	-- ours missing: strip our applied selfd bind from the live state
	local liveMissingOurs = {}
	for _, pr in ipairs(post) do
		if pr.boundWith ~= "Alt+sc_b" then
			liveMissingOurs[#liveMissingOurs + 1] = pr
		end
	end
	local okDiff, diff = m.diffLive(liveMissingOurs)
	t.ok(not okDiff, "watchdog notices our bind vanished")
	t.count(diff.oursMissing, "exactly the one missing pair reported", 1)

	-- foreign added: someone bound something new
	local liveForeign = {}
	for _, pr in ipairs(post) do
		liveForeign[#liveForeign + 1] = pr
	end
	liveForeign[#liveForeign + 1] = { command = "say", extra = "hi", boundWith = "Ctrl+sc_h" }
	okDiff, diff = m.diffLive(liveForeign)
	t.ok(not okDiff, "watchdog notices foreign addition")
	t.count(diff.foreignAdded, "one foreign addition", 1)
	t.count(diff.oursMissing, "our binds intact", 0)

	m.absorb(diff)
	okDiff = m.diffLive(liveForeign)
	t.ok(okDiff, "absorb folds foreign drift into expectations")

	----------------------------------------------------------------
	-- Overrides persist across model instances (serialize round-trip)
	----------------------------------------------------------------
	m = newModel()
	plan = m.setBinding("wantcloak", { "sc_j" })
	m.commitPlan(plan)
	local persisted = m.serializeOverrides()

	local m2 = core.model.new({
		catalogTable = fixture.catalogTable,
		presetKey = "luaui/configs/hotkeys/grid_keys.txt",
		persistedOverrides = persisted,
	})
	local startup = m2.refreshFromSnapshot(fixture.binds)
	t.eq(startup.commands, {
		"unbind sc_k wantcloak",
		"unbind Any+sc_k wantcloak",
		"bind Any+sc_j wantcloak",
	}, "persisted override re-applies on a fresh base")

	-- Different preset namespace: no commands
	local m3 = core.model.new({
		catalogTable = fixture.catalogTable,
		presetKey = "luaui/configs/hotkeys/legacy_keys.txt",
		persistedOverrides = persisted,
	})
	local startup3 = m3.refreshFromSnapshot(fixture.binds)
	t.count(startup3.commands, "overrides are namespaced per preset", 0)

	-- Orphan audit: override for a unit that no longer exists
	persisted.presets["luaui/configs/hotkeys/grid_keys.txt"]["gone_unit"] = { keysets = { "sc_q" } }
	local m4 = core.model.new({
		catalogTable = fixture.catalogTable,
		presetKey = "luaui/configs/hotkeys/grid_keys.txt",
		persistedOverrides = persisted,
	})
	m4.refreshFromSnapshot(fixture.binds)
	t.eq(m4.auditOverrides(), { "gone_unit" }, "orphaned overrides audited, not compiled")

	----------------------------------------------------------------
	-- Corrupted persisted override (the fromCapture double-"sc_" bug):
	-- dropped on load instead of forever re-emitting an unbind the
	-- engine can never satisfy.
	----------------------------------------------------------------
	local corrupt = {
		presets = {
			["luaui/configs/hotkeys/grid_keys.txt"] = {
				attack = { keysets = { "sc_sc_a", "Shift+sc_sc_a" } },
			},
		},
	}
	local m5 = core.model.new({
		catalogTable = fixture.catalogTable,
		presetKey = "luaui/configs/hotkeys/grid_keys.txt",
		persistedOverrides = corrupt,
	})
	t.eq(m5.sanitizedOverrides, { "luaui/configs/hotkeys/grid_keys.txt/attack" },
		"corrupt override reported for startup logging")
	local startup5 = m5.refreshFromSnapshot(fixture.binds)
	t.count(startup5.commands, "corrupt override dropped: attack falls back to base, no-op startup", 0)

	----------------------------------------------------------------
	-- Corrupted persisted override (bare-symbol chain, the pre-fix capture
	-- bug): "f9,f9" is a chain the engine can never bind ("Bad keysym"),
	-- so it's dropped on load exactly like the doubled-"sc_" corruption.
	----------------------------------------------------------------
	local chainCorrupt = {
		presets = {
			["luaui/configs/hotkeys/grid_keys.txt"] = {
				teamstatus_close = { keysets = { "f9,f9" } },
			},
		},
	}
	local m6 = core.model.new({
		catalogTable = fixture.catalogTable,
		presetKey = "luaui/configs/hotkeys/grid_keys.txt",
		persistedOverrides = chainCorrupt,
	})
	t.eq(m6.sanitizedOverrides, { "luaui/configs/hotkeys/grid_keys.txt/teamstatus_close" },
		"bare-symbol chain override reported for startup logging")
	local startup6 = m6.refreshFromSnapshot(fixture.binds)
	t.count(startup6.commands, "bare-symbol chain override dropped: falls back to base, no-op startup", 0)

	-- Same corruption, scancode-prefixed form: chaining F9 is rejected by the
	-- engine regardless of string representation, so this must be caught too
	-- (this exact shape is what an earlier, now-reverted fix attempt stored).
	local scChainCorrupt = {
		presets = {
			["luaui/configs/hotkeys/grid_keys.txt"] = {
				teamstatus_close = { keysets = { "sc_f9,sc_f9" } },
			},
		},
	}
	local m7 = core.model.new({
		catalogTable = fixture.catalogTable,
		presetKey = "luaui/configs/hotkeys/grid_keys.txt",
		persistedOverrides = scChainCorrupt,
	})
	t.eq(m7.sanitizedOverrides, { "luaui/configs/hotkeys/grid_keys.txt/teamstatus_close" },
		"scancode-form chain of a non-chainable key reported for startup logging")
	local startup7 = m7.refreshFromSnapshot(fixture.binds)
	t.count(startup7.commands, "scancode-form chain override dropped: falls back to base, no-op startup", 0)
end
