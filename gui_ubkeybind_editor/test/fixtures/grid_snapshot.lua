-- Test fixture: a miniature preset snapshot + catalog modeling every real
-- BAR binding pattern found in luaui/configs/hotkeys/*.txt:
--
--   shift-companion pairs        attack on sc_a / Shift+sc_a (+ drifted sc_x)
--   queued pairs                 selfd / selfd queued
--   any-wrap                     buildsplit; wantcloak double-bound plain+Any
--   keychain + companion         onoff 0 on sc_b,sc_b / Shift+sc_b,Shift+sc_b
--   parameterized (values)       group select 0..2 bound, 3..9 catalog-only
--   parameterized (discovered)   specteam (param != key!), firestate chains
--   two-token params + Any       gridmenu_key "1 1".. + discovered "4 1"
--   exotic pass-through actions  select query, chain ... | say ...
--   multi-action keyset          five actions stacked on esc (one managed)
--   unmanaged bulk               buildunit_* stack on sc_z
--
-- The `binds` list is in DEFINED ORDER — bind order on shared keysets (esc)
-- is engine behavior and the compiler must preserve it.

local function b(command, extra, boundWith)
	return { command = command, extra = extra, boundWith = boundWith }
end

local binds = {
	-- esc stack: order is behavior (test 9 rebuilds it)
	b("select", "AllMap++_ClearSelection_SelectNum_0+", "esc"),
	b("quitmessage", "", "esc"),
	b("teamstatus_close", "", "esc"),
	b("customgameinfo_close", "", "esc"),
	b("buildmenu_pregame_deselect", "", "esc"),

	-- shift-companion, one keyset drifted (no companion on sc_x)
	b("attack", "", "sc_a"),
	b("attack", "", "Shift+sc_a"),
	b("attack", "", "sc_x"),

	-- auto_shift base without companion (areaattack, grid_keys style)
	b("areaattack", "", "Ctrl+sc_a"),

	-- queued pair
	b("selfd", "", "Ctrl+sc_b"),
	b("selfd", "queued", "Ctrl+Shift+sc_b"),

	-- direct at the companion collision spot for the conflict test
	b("quitforce", "", "Ctrl+Shift+esc"),

	-- any_wrap
	b("buildsplit", "", "Any+space"),
	b("wantcloak", "", "sc_k"),      -- redundant plain duplicate...
	b("wantcloak", "", "Any+sc_k"),  -- ...of the real Any bind

	-- keychain with shifted companion (every press shifted)
	b("onoff", "0", "sc_b,sc_b"),
	b("onoff", "0", "Shift+sc_b,Shift+sc_b"),

	-- parameterized, catalog-listed values (0..9), only 0..2 bound.
	-- command/extra split exercises the identity join.
	b("group", "select 0", "0"),
	b("group", "select 1", "1"),
	b("group", "select 2", "2"),

	-- parameterized by discovery, param != key
	b("specteam", "0", "1"),
	b("specteam", "1", "2"),

	-- two-token params + any_wrap; "4 1" is not in catalog values
	b("gridmenu_key", "1 1", "Any+sc_q"),
	b("gridmenu_key", "1 2", "Any+sc_w"),
	b("gridmenu_key", "4 1", "Any+sc_t"),

	-- chain-prefix family via discovery (deliberate idiom, not a conflict)
	b("firestate", "2", "sc_l"),
	b("firestate", "0", "sc_l,sc_l"),
	b("firestate", "1", "sc_l,sc_l,sc_l"),

	-- exotic pass-through action strings
	b("select", "AllMap++_ClearSelection_SelectAll+", "Ctrl+sc_e"),
	b("chain", "force forcestart | say !cv forcestart", "Alt+sc_f"),

	-- unmanaged bulk (legacy buildunit stack)
	b("buildunit_armmex", "", "sc_z"),
	b("buildunit_armmex", "", "Shift+sc_z"),
	b("buildunit_armsolar", "", "sc_z"),
	b("buildunit_armsolar", "", "Shift+sc_z"),
}

local catalogTable = {
	version = 2,
	categories = {
		{
			name = "orders",
			label = "Unit Orders",
			entries = {
				{ id = "attack", label = "Attack", tooltip = "Order selected units to attack",
					processor = { type = "auto_shift", action = "attack" } },
				{ id = "areaattack", label = "Area Attack",
					processor = { type = "auto_shift", action = "areaattack" } },
				{ id = "selfd", label = "Self Destruct",
					processor = { type = "queued_pair", actions = { "selfd", "selfd queued" } } },
				{ id = "buildsplit", label = "Build Split",
					processor = { type = "any_wrap", action = "buildsplit" } },
				{ id = "wantcloak", label = "Cloak",
					processor = { type = "any_wrap", action = "wantcloak" } },
				{ id = "onoff_off", label = "Turn Off",
					processor = { type = "auto_shift", action = "onoff 0" } },
			},
		},
		{
			name = "selection",
			label = "Selection & Groups",
			entries = {
				{ id = "group_select", label = "Select Control Group",
					processor = { type = "direct", action = "group select" },
					params = { values = { "0", "1", "2", "3", "4", "5", "6", "7", "8", "9" } } },
				{ id = "specteam", label = "Watch Player",
					processor = { type = "direct", action = "specteam" },
					params = {} },
				{ id = "select_all", label = "Select All Units",
					processor = { type = "direct", action = "select AllMap++_ClearSelection_SelectAll+" } },
			},
		},
		{
			name = "interface",
			label = "Interface",
			entries = {
				{ id = "gridmenu_key", label = "Grid Menu Key",
					processor = { type = "any_wrap", action = "gridmenu_key" },
					params = { values = { "1 1", "1 2", "3 4" }, labelFormat = "Row %s, Column %s" } },
				{ id = "firestate", label = "Fire State",
					processor = { type = "direct", action = "firestate" },
					params = {} },
				{ id = "teamstatus_close", label = "Close Team Status",
					processor = { type = "direct", action = "teamstatus_close" } },
				{ id = "quitforce", label = "Force Quit",
					processor = { type = "direct", action = "quitforce" } },
				{ id = "force_start", label = "Force Start", locked = true,
					processor = { type = "direct", action = "chain force forcestart | say !cv forcestart" } },
			},
		},
	},
}

return {
	binds = binds,
	catalogTable = catalogTable,
}
