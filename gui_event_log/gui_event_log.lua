if not RmlUi then
	return false
end

function widget:GetInfo()
	return {
		name      = "Event log",
		desc      = ".",
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
        example = "Hello World",
		events = {
			{ time = "12:18", type = "alert", message = "Example 1" },
			{ time = "12:18", type = "alert", message = "Example 2" },
			{ time = "12:18", type = "alert", message = "Example 3" },
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
