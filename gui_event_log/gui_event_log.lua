if not RmlUi then
	return false
end

local widget = widget ---@type Widget

function widget:GetInfo()
	return {
		name = "gui_event_log",
		desc = "Generated RML widget template",
		author = "Generated from rml_starter/generate-widget.sh",
		date = "2025",
		license = "GNU GPL, v2 or later",
		layer = -1000000,
		enabled = true,
	}
end

-- Constants
local WIDGET_NAME = "gui_event_log"
local MODEL_NAME = "gui_event_log_model"
local RML_PATH = "LuaUI/Widgets/gui_event_log/gui_event_log.rml"

-- Widget state
local document
local dm_handle

-- Initial data model
local init_model = {
	debugMode = false,
	events = {
		{ message = "Event 1 - unit",     time = os.time(), type = "info",    icon = "/icons/air.png", unitid = 1234 },
		{ message = "Event 2",            time = os.time(), type = "warning", icon = "/icons/air.png", unitid = 5678 },
		{ message = "Event 3 - location", time = os.time(), type = "error",   icon = "/icons/air.png", point = { x = 100, z = 200 } },
	},
	test = function(dm_handle, e)
		Spring.Echo(WIDGET_NAME .. ": Clicked event:", e) -- Simple print for debugging
	end,
}

function widget:Initialize()
	if widget:GetInfo().enabled == false then
		Spring.Echo(WIDGET_NAME .. ": Widget is disabled, skipping initialization")
		return false
	end

	Spring.Echo(WIDGET_NAME .. ": Initializing widget...")

	-- Get the shared RML context
	widget.rmlContext = RmlUi.GetContext("shared")
	if not widget.rmlContext then
		Spring.Echo(WIDGET_NAME .. ": ERROR - Failed to get RML context")
		return false
	end

	-- Create and bind the data model
	dm_handle = widget.rmlContext:OpenDataModel(MODEL_NAME, init_model)
	if not dm_handle then
		Spring.Echo(WIDGET_NAME .. ": ERROR - Failed to create data model")
		return false
	end

	Spring.Echo(WIDGET_NAME .. ": Data model created successfully")

	-- Load the RML document
	document = widget.rmlContext:LoadDocument(RML_PATH, widget)
	if not document then
		Spring.Echo(WIDGET_NAME .. ": ERROR - Failed to load document: " .. RML_PATH)
		widget:Shutdown()
		return false
	end

	-- Apply styles and show the document
	document:ReloadStyleSheet()
	document:Show()
	Spring.Echo(WIDGET_NAME .. ": Widget initialized successfully")

	return true
end

function widget:Shutdown()
	Spring.Echo(WIDGET_NAME .. ": Shutting down widget...")

	-- Clean up data model
	if widget.rmlContext and dm_handle then
		widget.rmlContext:RemoveDataModel(MODEL_NAME)
		dm_handle = nil
	end

	-- Close document
	if document then
		document:Close()
		document = nil
	end

	widget.rmlContext = nil
	Spring.Echo(WIDGET_NAME .. ": Shutdown complete")
end

function widget:Update()
	if dm_handle then
		-- dm_handle.currentTime = os.date("%H:%M:%S")
	end
end

function widget:OnEventClick(model_handle, e, args)
	-- Print the structure of the event object for debugging
	Spring.Echo(WIDGET_NAME .. ": Event clicked:")
	Spring.Echo(e) -- Simple print for debugging
	Spring.Echo(args) -- Print additional arguments for debugging
end

-- Widget functions callable from RML
function widget:Reload()
	Spring.Echo(WIDGET_NAME .. ": Reloading widget...")
	widget:Shutdown()
	widget:Initialize()
end

function widget:ToggleDebugger()
	if dm_handle then
		dm_handle.debugMode = not dm_handle.debugMode

		if dm_handle.debugMode then
			RmlUi.SetDebugContext('shared')
			Spring.Echo(WIDGET_NAME .. ": RmlUi debugger enabled")
		else
			RmlUi.SetDebugContext(nil)
			Spring.Echo(WIDGET_NAME .. ": RmlUi debugger disabled")
		end
	end
end
