-- ubKeybind Editor — widget config persistence.
--
-- Storage is the standard BAR path: widget:GetConfigData()/SetConfigData(),
-- auto-persisted by the widget handler into LuaUI/Config/BYAR.lua.
-- SetConfigData runs BEFORE Initialize, so the widget stashes the raw table
-- and hands it here during init.
--
-- Schema:
--   { version = 1,
--     overrides = <core overrides.serialize() table>,
--     ui = { collapsed = { [categoryName] = true }, levelFilter = "common" } }

local Persistence = {}

Persistence.CURRENT_VERSION = 1

-- fromVersion -> function(data) mutating data up one version.
Persistence.migrations = {}

---Tolerant load: returns overridesData (core format or nil), uiPrefs table.
function Persistence.load(configData)
	if type(configData) ~= "table" then
		return nil, {}
	end

	local version = tonumber(configData.version) or 0
	while version < Persistence.CURRENT_VERSION do
		local migrate = Persistence.migrations[version]
		if not migrate then
			break
		end
		migrate(configData)
		version = version + 1
	end

	local overridesData = type(configData.overrides) == "table" and configData.overrides or nil
	local uiPrefs = type(configData.ui) == "table" and configData.ui or {}
	return overridesData, uiPrefs
end

function Persistence.dump(coreModel, uiPrefs)
	return {
		version = Persistence.CURRENT_VERSION,
		overrides = coreModel and coreModel.serializeOverrides() or nil,
		ui = uiPrefs or {},
	}
end

return Persistence
