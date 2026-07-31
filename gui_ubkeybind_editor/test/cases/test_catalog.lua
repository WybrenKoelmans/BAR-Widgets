-- catalog.lua: mergeWidgetActions (custom widget-registered actions surfaced
-- as a synthetic, fully-bindable "Custom Widget Actions" category).

return function(core, t, fixture)
	local catalog = core.catalog

	-- A brand-new action name merges in as a new, direct-processor unit.
	do
		local cat = catalog.load(fixture.catalogTable)
		catalog.mergeWidgetActions(cat, {
			widgetselector = { "Widget Selector" },
		})
		local entry = cat.entriesById["widget:widgetselector"]
		t.ok(entry ~= nil, "new widget action becomes a catalog entry")
		t.eq(entry and entry.processor, { type = "direct", action = "widgetselector" },
			"synthesized entry uses the direct processor over the raw action")
		t.contains(cat.categories, function(c) return c.name == "widget_actions" end,
			"a 'Custom Widget Actions' category is created")

		local units = catalog.units(cat)
		t.ok(units["widget:widgetselector"] ~= nil, "unit expansion picks up the merged entry")
	end

	-- An action already claimed by a real catalog entry (e.g. "attack") is
	-- left alone — no duplicate entry, no clash with the real unit.
	do
		local cat = catalog.load(fixture.catalogTable)
		local before = #cat.categories
		catalog.mergeWidgetActions(cat, {
			attack = { "Some Other Widget" },
		})
		t.eq(#cat.categories, before, "already-claimed action does not spawn a new category")
		t.ok(cat.entriesById["widget:attack"] == nil, "already-claimed action is not duplicated under a widget id")
	end

	-- Two widgets registering the same action name merge into one entry
	-- listing both.
	do
		local cat = catalog.load(fixture.catalogTable)
		catalog.mergeWidgetActions(cat, {
			chain = { "Chain Actions", "Some Other Widget" },
		})
		local entry = cat.entriesById["widget:chain"]
		t.ok(entry ~= nil, "shared action name merges to a single entry")
		t.ok(entry and entry.tooltip:find("Chain Actions", 1, true) ~= nil
			and entry.tooltip:find("Some Other Widget", 1, true) ~= nil,
			"tooltip lists every widget that registered the action")
	end

	-- A bare action claimed only via a parameterized entry's family marker
	-- ("group select *", not "group select") must still be recognized as
	-- already-claimed, not duplicated as a raw widget entry.
	do
		local cat = catalog.load(fixture.catalogTable)
		local before = #cat.categories
		catalog.mergeWidgetActions(cat, {
			["group select"] = { "Some Widget" },
		})
		t.eq(#cat.categories, before, "action claimed via a parameterized family marker is not duplicated")
		t.ok(cat.entriesById["widget:group select"] == nil,
			"parameterized entry's bare action does not spawn a widget entry")
	end

	-- Nil/empty discovery is a no-op.
	do
		local cat = catalog.load(fixture.catalogTable)
		local before = #cat.categories
		catalog.mergeWidgetActions(cat, nil)
		catalog.mergeWidgetActions(cat, {})
		t.eq(#cat.categories, before, "nil/empty widget actions leave the catalog untouched")
	end
end
