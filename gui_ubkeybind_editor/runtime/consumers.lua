-- ubKeybind Editor — consumer notification.
--
-- After binds change, widgets that cache hotkey labels must be told. BAR's
-- cmd_bar_hotkeys does this after a preset keyreload, but its list is a local
-- and calling WG['bar_hotkeys'].reloadBindings() would keyreload and wipe our
-- live edits — so we replicate the list here.
--
-- NOTIFY_LIST mirrors reloadWidgetsBindings() in
-- luaui/Widgets/cmd_bar_hotkeys.lua (line 25). If BAR adds a consumer we
-- miss, only that menu's hotkey LABELS lag, and any preset switch re-notifies
-- everything through bar_hotkeys anyway.

local Consumers = {}

Consumers.NOTIFY_LIST = { "buildmenu", "ordermenu", "keybinds", "cmd_blueprint" }

function Consumers.notify()
	for _, name in ipairs(Consumers.NOTIFY_LIST) do
		local w = WG[name]
		if w and w.reloadBindings then
			pcall(w.reloadBindings)
		end
	end
end

return Consumers
