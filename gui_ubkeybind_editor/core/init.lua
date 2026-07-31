-- ubKeybind Editor — core loader.
--
-- The core is pure Lua 5.1: no Spring, RmlUi or VFS references. Engine calls
-- are injected at the boundary (see model.lua deps), which keeps every module
-- runnable under a plain Lua interpreter for the offline test harness.
-- JSON decoding is a boundary concern too: callers decode the catalog with
-- the base game's common/luaUtilities/json.lua and hand core plain tables.
--
-- Each core file returns a constructor `function(core) ... return M end`.
-- This loader wires them together and returns the registry.
--
-- Usage (in-game):
--   local function include(name)
--     return VFS.Include(CORE_DIR .. name, nil, VFS.RAW_FIRST)
--   end
--   local core = include("init.lua")(include)
--
-- Usage (offline tests):
--   local function include(name) return dofile(CORE_DIR .. name) end
--   local core = include("init.lua")(include)

return function(include)
	local core = {}

	core.keyset = include("keyset.lua")(core)
	core.processors = include("processors.lua")(core)
	core.catalog = include("catalog.lua")(core)
	core.import = include("import.lua")(core)
	core.overrides = include("overrides.lua")(core)
	core.compile = include("compile.lua")(core)
	core.conflicts = include("conflicts.lua")(core)
	core.model = include("model.lua")(core)

	return core
end
