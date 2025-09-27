if not RmlUi then
	return false
end

function widget:GetInfo()
	return {
		name      = "Event log",
		desc      = "A list of important events. Most events are interactive by clicking the item.",
		author    = "uBdead",
		date      = "Sept 2025",
		license   = "GPL V2 or later",
		layer     = -828888,
		handler   = true,
		enabled   = true
	}
end

local document
widget.rmlContext = nil

local dm_handle

function widget:Initialize()
	widget.rmlContext = RmlUi.CreateContext(widget.whInfo.name)

	-- use the DataModel handle to set values
	-- only keys declared at the DataModel's creation can be used
	dm_handle = widget.rmlContext:OpenDataModel("gui_event_log", {
		events = {
			{ time = "12:01", type = "alert", message = "Nuclear missile ready" },
			{ time = "12:03", type = "warning", message = "Commander under attack" },
			{ time = "12:05", type = "info", message = "Metal extractor built" },
			{ time = "12:07", type = "alert", message = "Enemy superweapon detected" },
			{ time = "12:10", type = "info", message = "Ally has shared resources" },
			{ time = "12:12", type = "warning", message = "Base perimeter breached" },
			{ time = "12:15", type = "info", message = "Unit promoted: Veteran" },
			{ time = "12:18", type = "alert", message = "Commander destroyed" },
		},
	});

	document = widget.rmlContext:LoadDocument("LuaUI/Widgets/gui_event_log/gui_event_log.rml", widget)
	document:ReloadStyleSheet()
	document:Show()
end

function widget:Shutdown()
	if document then
		document:Close()
	end
	if widget.rmlContext then
		RmlUi.RemoveContext(widget.whInfo.name)
	end
end
