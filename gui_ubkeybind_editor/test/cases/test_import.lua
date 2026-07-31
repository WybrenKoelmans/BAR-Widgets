-- catalog.lua + import.lua against the grid-style fixture snapshot.

return function(core, t, fixture)
	local K = core.keyset

	local cat, errs = core.catalog.load(fixture.catalogTable)
	t.ok(cat ~= nil, "catalog loads")
	t.count(errs, "catalog has no validation errors", 0)

	local result = core.import.run(fixture.binds, cat)
	t.count(result.warnings, "import has no warnings", 0)

	local function canonList(keysets)
		local out = {}
		for i, ks in ipairs(keysets) do
			out[i] = K.canonical(ks)
		end
		return out
	end

	local units = result.units

	-- Shift-companion pairing with drift
	t.eq(canonList(units.attack.keysets), { "sc_a", "sc_x" }, "attack: two user keysets")
	t.contains(units.attack.drift, function(d) return d.kind == "missing_companion" end,
		"attack: sc_x missing companion flagged")
	t.count(units.attack.pairs, "attack: three engine pairs recorded", 3)

	-- Queued pair
	t.eq(canonList(units.selfd.keysets), { "ctrl+sc_b" }, "selfd: one keyset from the pair")
	t.count(units.selfd.drift, "selfd: clean", 0)

	-- Any-wrap double bind
	t.eq(canonList(units.wantcloak.keysets), { "sc_k" }, "wantcloak: collapses plain+Any")
	t.contains(units.wantcloak.drift, function(d) return d.kind == "redundant_plain" end,
		"wantcloak: redundant plain flagged")

	-- Keychain companion
	t.eq(canonList(units.onoff_off.keysets), { "sc_b,sc_b" }, "onoff: chain keyset")
	t.count(units.onoff_off.drift, "onoff: chain pair clean", 0)

	-- Parameterized with listed values: 10 units, 0..2 bound, 3..9 empty
	t.eq(canonList(units["group_select/0"].keysets), { "0" }, "group select 0 bound to key 0")
	t.eq(canonList(units["group_select/2"].keysets), { "2" }, "group select 2 bound")
	t.count(units["group_select/7"].keysets, "group select 7 exists unbound", 0)
	t.ok(units["group_select/7"].discovered == nil, "listed params are not 'discovered'")

	-- Discovery with param != key
	t.eq(canonList(units["specteam/0"].keysets), { "1" }, "specteam param 0 on key 1 (param != key)")
	t.eq(canonList(units["specteam/1"].keysets), { "2" }, "specteam param 1 on key 2")

	-- Two-token params, any_wrap, discovery beyond listed values
	t.eq(canonList(units["gridmenu_key/1 1"].keysets), { "sc_q" }, "gridmenu 1 1 unwrapped from Any")
	t.count(units["gridmenu_key/3 4"].keysets, "gridmenu 3 4 listed but unbound", 0)
	local discoveredUnit = units["gridmenu_key/4 1"]
	t.ok(discoveredUnit ~= nil and discoveredUnit.discovered == true, "gridmenu 4 1 discovered from snapshot")
	t.eq(discoveredUnit and discoveredUnit.paramLabel, "Row 4, Column 1", "labelFormat applied to discovered param")

	-- Chain-prefix family via discovery, numeric sort
	t.eq(canonList(units["firestate/0"].keysets), { "sc_l,sc_l" }, "firestate 0 double-tap")
	t.eq(canonList(units["firestate/2"].keysets), { "sc_l" }, "firestate 2 single tap")
	local fsOrder = {}
	for _, unitId in ipairs(result.order) do
		if unitId:sub(1, 10) == "firestate/" then
			fsOrder[#fsOrder + 1] = unitId
		end
	end
	t.eq(fsOrder, { "firestate/0", "firestate/1", "firestate/2" }, "discovered params sorted numerically")

	-- Exotic actions pass through as identities
	t.eq(canonList(units.select_all.keysets), { "ctrl+sc_e" }, "select query action matched")
	t.eq(canonList(units.force_start.keysets), { "alt+sc_f" }, "chain|say action matched")
	t.ok(units.force_start.locked, "locked flag carried to unit")

	-- Managed esc member
	t.eq(canonList(units.teamstatus_close.keysets), { "escape" }, "teamstatus_close on esc")

	-- Unmanaged bucket: 4 esc actions + 4 buildunit binds
	t.count(result.unmanaged, "unmanaged bucket size", 8)
	t.contains(result.unmanaged, function(pr) return pr.action == "buildunit_armmex" end,
		"buildunit stack is unmanaged")
	t.contains(result.unmanaged, function(pr) return pr.action == "quitmessage" end,
		"quitmessage is unmanaged")

	-- livePairs preserves snapshot order
	t.eq(#result.livePairs, #fixture.binds, "livePairs covers the whole snapshot")
	t.eq(result.livePairs[1].action, "select AllMap++_ClearSelection_SelectNum_0+",
		"identity join lowercases only the command token, extra stays case-preserved")

	-- Import is idempotent: run again, same shape
	local again = core.import.run(fixture.binds, cat)
	t.eq(canonList(again.units.attack.keysets), canonList(units.attack.keysets), "re-import is stable")

	-- Catalog validation: duplicate action claim rejected
	local badCat, badErrs = core.catalog.load({
		version = 2,
		categories = { {
			name = "x",
			entries = {
				{ id = "a", label = "A", processor = { type = "direct", action = "attack" } },
				{ id = "b", label = "B", processor = { type = "direct", action = "attack" } },
			},
		} },
	})
	t.ok(badCat ~= nil and badCat.entriesById.a ~= nil and badCat.entriesById.b == nil,
		"duplicate action claim skips the second entry")
	t.ok(#badErrs > 0, "duplicate action claim reported")

	-- Wrong version rejected outright
	local noCat = core.catalog.load({ version = 1, categories = {} })
	t.ok(noCat == nil, "catalog v1 rejected")

	----------------------------------------------------------------
	-- Level metadata: cumulative visibility tiers
	----------------------------------------------------------------
	t.eq(core.catalog.LEVELS, { "common", "uncommon", "advanced", "all" }, "level order")
	t.eq(core.catalog.levelRank("common"), 1, "common ranks lowest")
	t.ok(core.catalog.levelRank("advanced") > core.catalog.levelRank("uncommon"),
		"advanced ranks above uncommon")
	t.eq(core.catalog.levelRank("all"), 4, "all ranks highest")
	t.eq(core.catalog.levelRank(nil), core.catalog.levelRank("common"),
		"nil/unknown level ranks as common (most visible)")

	local levelCat, levelErrs = core.catalog.load({
		version = 2,
		categories = { {
			name = "x",
			entries = {
				{ id = "unspecified", label = "Unspecified", processor = { type = "direct", action = "foo1" } },
				{ id = "explicit_advanced", label = "Explicit", level = "advanced",
					processor = { type = "direct", action = "foo2" } },
				{ id = "bad_level", label = "Bad", level = "obscure",
					processor = { type = "direct", action = "foo3" } },
			},
		} },
	})
	t.eq(levelCat.entriesById.unspecified.level, "common", "unspecified entry defaults to common")
	t.eq(levelCat.entriesById.explicit_advanced.level, "advanced", "explicit level carried through")
	t.ok(levelCat.entriesById.bad_level == nil, "invalid level rejects the entry")
	t.ok(#levelErrs > 0, "invalid level reported")

	local levelUnits = core.catalog.units(levelCat)
	t.eq(levelUnits.unspecified.level, "common", "unit inherits entry level (default)")
	t.eq(levelUnits.explicit_advanced.level, "advanced", "unit inherits entry level (explicit)")
end
