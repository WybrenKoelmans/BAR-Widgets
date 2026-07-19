-- Smoke test: real BAR preset files + real shipped catalog through the core.
-- Emulates the engine's uikeys loader (bind/keyload/unbindaction/unbindkeyset)
-- to build a realistic GetKeyBindings snapshot.

local coreDir = "C:/Users/wybre/AppData/Local/Programs/Beyond-All-Reason/data/LuaUI/Widgets/gui_ubkeybind_editor/core/"
local widgetDir = "C:/Users/wybre/AppData/Local/Programs/Beyond-All-Reason/data/LuaUI/Widgets/gui_ubkeybind_editor/"
local repoRoot = "C:/Users/wybre/Development/Beyond-All-Reason/"

local function include(name) return dofile(coreDir .. name) end
local core = include("init.lua")(include)

local function readFile(p)
	local f = io.open(p, "r")
	if not f then error("missing " .. p) end
	local s = f:read("*a")
	f:close()
	return s
end

local function loadPreset(relPath)
	local binds = {}
	local function canonKs(s)
		local ks = core.keyset.parse(s)
		return ks and core.keyset.canonical(ks) or s:lower()
	end
	local function walk(path)
		local text = readFile(repoRoot .. path)
		for line in text:gmatch("[^\r\n]+") do
			line = line:gsub("//.*$", "")
			line = line:match("^%s*(.-)%s*$")
			if line ~= "" then
				local cmd, rest = line:match("^(%S+)%s*(.*)$")
				cmd = cmd and cmd:lower()
				if cmd == "keyload" then
					walk((rest:gsub("^%s+", ""):gsub("%s+$", "")))
				elseif cmd == "bind" then
					local ks, action = rest:match("^(%S+)%s+(.+)$")
					if ks and action then
						local acmd, extra = action:match("^(%S+)%s*(.*)$")
						binds[#binds + 1] = { command = acmd, extra = extra or "", boundWith = ks }
					end
				elseif cmd == "unbindall" then
					binds = {}
				elseif cmd == "unbindaction" then
					local target = rest:lower():match("^%s*(.-)%s*$")
					local kept = {}
					for _, b in ipairs(binds) do
						local full = (b.extra ~= "" and (b.command .. " " .. b.extra) or b.command):lower()
						if full ~= target and b.command:lower() ~= target then
							kept[#kept + 1] = b
						end
					end
					binds = kept
				elseif cmd == "unbindkeyset" or cmd == "unbind" then
					local ksStr = rest:match("^(%S+)")
					local target = ksStr and canonKs(ksStr)
					local actionPart = rest:match("^%S+%s+(.+)$")
					local kept = {}
					for _, b in ipairs(binds) do
						local match = canonKs(b.boundWith) == target
						if match and actionPart then
							local full = (b.extra ~= "" and (b.command .. " " .. b.extra) or b.command):lower()
							match = full == actionPart:lower()
						end
						if not match then
							kept[#kept + 1] = b
						end
					end
					binds = kept
				end
			end
		end
	end
	walk(relPath)
	return binds
end

-- Base game JSON library, loaded from the dev repo checkout (core carries no
-- JSON of its own; in-game the widget VFS.Includes the same file).
local Json = dofile(repoRoot .. "common/luaUtilities/json.lua")
local decoded = Json.decode(readFile(widgetDir .. "keybinds_catalog.json"))

local failures = 0

for _, preset in ipairs({
	"luaui/configs/hotkeys/grid_keys.txt",
	"luaui/configs/hotkeys/legacy_keys.txt",
	"luaui/configs/hotkeys/grid_keys_60pct.txt",
	"luaui/configs/hotkeys/legacy_keys_60pct.txt",
}) do
	local binds = loadPreset(preset)
	local m, errs = core.model.new({
		catalogTable = decoded,
		presetKey = preset,
		persistedOverrides = nil,
	})
	if not m then
		print("FATAL: " .. table.concat(errs, "; "))
		os.exit(1)
	end
	local plan, warnings = m.refreshFromSnapshot(binds)

	local rows = m.listUnits()
	local bound, unbound, driftCount = 0, 0, 0
	local driftKinds = {}
	for _, r in ipairs(rows) do
		if #r.keysets > 0 then bound = bound + 1 else unbound = unbound + 1 end
		for _, d in ipairs(r.drift or {}) do
			driftCount = driftCount + 1
			driftKinds[d.kind] = (driftKinds[d.kind] or 0) + 1
		end
	end

	print(("== %s"):format(preset))
	print(("   binds=%d units=%d bound=%d unbound=%d"):format(#binds, #rows, bound, unbound))
	local kindStrs = {}
	for k, n in pairs(driftKinds) do kindStrs[#kindStrs + 1] = k .. "=" .. n end
	table.sort(kindStrs)
	print("   drift: " .. (next(driftKinds) and table.concat(kindStrs, " ") or "none"))
	for _, w in ipairs(warnings) do
		print("   WARN: " .. w)
	end
	if #plan.commands > 0 then
		failures = failures + 1
		print("   *** ROUND-TRIP VIOLATION: " .. #plan.commands .. " commands on empty store:")
		for i = 1, math.min(10, #plan.commands) do
			print("       " .. plan.commands[i])
		end
	else
		print("   round-trip: no-op OK")
	end

	-- Quick end-to-end edit exercise on the real catalog
	m.commitPlan(plan)
	local p2, err = m.setBinding("attack", { "sc_y" })
	if not p2 then
		failures = failures + 1
		print("   *** setBinding(attack) failed: " .. tostring(err))
	else
		local hasShiftCompanion = false
		for _, c in ipairs(p2.commands) do
			if c == "bind Shift+sc_y attack" then hasShiftCompanion = true end
		end
		if not hasShiftCompanion then
			failures = failures + 1
			print("   *** attack rebind missing Shift companion:")
			for _, c in ipairs(p2.commands) do print("       " .. c) end
		else
			print("   attack rebind emits companion OK (" .. #p2.commands .. " cmds)")
		end
	end
end

print(failures == 0 and "SMOKE OK" or ("SMOKE FAILED (" .. failures .. ")"))
os.exit(failures == 0 and 0 or 1)
