-- ubKeybind Editor — offline test harness.
--
-- Runs under any Lua 5.1-compatible interpreter (LuaJIT matches Spring):
--   luajit test/run_tests.lua           (from the widget folder)
--   luajit run_tests.lua                (from the test folder)
--
-- The core is pure Lua with injected engine I/O, so no Spring stubs are
-- needed for these tests; fixtures feed plain tables.

local scriptPath = (arg and arg[0]) or "run_tests.lua"
local testDir = scriptPath:match("^(.*[/\\])") or ""
local coreDir = testDir .. "../core/"
local runtimeDir = testDir .. "../runtime/"

local function include(name)
	return dofile(coreDir .. name)
end

local core = include("init.lua")(include)

-- Runtime modules (capture, etc.) are plain modules, not core constructors.
local ctx = {
	requireRuntime = function(name)
		return dofile(runtimeDir .. name)
	end,
}

----------------------------------------------------------------------
-- Tiny test framework
----------------------------------------------------------------------

local t = {
	pass = 0,
	fail = 0,
	failures = {},
	current = "?",
}

local function serialize(v, depth)
	depth = depth or 0
	if depth > 3 then
		return "..."
	end
	if type(v) == "table" then
		local parts = {}
		local n = 0
		for k, val in pairs(v) do
			n = n + 1
			if n > 12 then
				parts[#parts + 1] = "..."
				break
			end
			local key = type(k) == "number" and "" or (tostring(k) .. "=")
			parts[#parts + 1] = key .. serialize(val, depth + 1)
		end
		return "{" .. table.concat(parts, ", ") .. "}"
	end
	if type(v) == "string" then
		return string.format("%q", v)
	end
	return tostring(v)
end

local function deepEq(a, b)
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for k, v in pairs(a) do
		if not deepEq(v, b[k]) then
			return false
		end
	end
	for k in pairs(b) do
		if a[k] == nil then
			return false
		end
	end
	return true
end

local function record(ok, label, detail)
	if ok then
		t.pass = t.pass + 1
	else
		t.fail = t.fail + 1
		local msg = "[" .. t.current .. "] " .. label .. (detail and (" — " .. detail) or "")
		t.failures[#t.failures + 1] = msg
		print("FAIL " .. msg)
	end
end

function t.ok(cond, label)
	record(not not cond, label)
end

function t.eq(actual, expected, label)
	record(deepEq(actual, expected), label,
		"expected " .. serialize(expected) .. ", got " .. serialize(actual))
end

function t.contains(list, predicate, label)
	for _, item in ipairs(list or {}) do
		if predicate(item) then
			record(true, label)
			return item
		end
	end
	record(false, label, "no matching item in " .. serialize(list))
	return nil
end

function t.count(list, label, expected)
	record(#(list or {}) == expected, label,
		"expected " .. expected .. " items, got " .. #(list or {}) .. ": " .. serialize(list))
end

----------------------------------------------------------------------
-- Run cases
----------------------------------------------------------------------

local fixture = dofile(testDir .. "fixtures/grid_snapshot.lua")

local cases = {
	"test_keyset",
	"test_processors",
	"test_catalog",
	"test_import",
	"test_compile",
	"test_conflicts",
	"test_capture",
	"test_engine_sync",
}

for _, name in ipairs(cases) do
	t.current = name
	local case = dofile(testDir .. "cases/" .. name .. ".lua")
	local ok, err = pcall(case, core, t, fixture, ctx)
	if not ok then
		record(false, "case crashed", tostring(err))
	end
end

----------------------------------------------------------------------

print(string.rep("-", 60))
print(string.format("%d passed, %d failed", t.pass, t.fail))
if t.fail > 0 then
	os.exit(1)
end
print("OK")
