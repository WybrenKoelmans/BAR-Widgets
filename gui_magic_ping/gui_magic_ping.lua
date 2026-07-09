local widget = widget ---@type Widget

function widget:GetInfo()
    return {
        name = "Magic Ping",
        desc = "Invoking a default Ping (map marker) near a unit or thing, automatically labels it.",
        author = "uBdead",
        date = "June 2026",
        license = "GNU GPL, v2 or later",
        layer = -10000,
        enabled = true
    }
end

local scanDistance = 100 -- elmos around the ping to search for units/features

local spGetUnitsInCylinder = Spring.GetUnitsInCylinder
local spGetUnitDefID = Spring.GetUnitDefID
local spIsUnitAllied = Spring.IsUnitAllied
local spMarkerAddPoint = Spring.MarkerAddPoint
local spGetUnitTeam = Spring.GetUnitTeam
local spGetFeaturesInCylinder = Spring.GetFeaturesInCylinder
local spGetTeamInfo = Spring.GetTeamInfo
local spGetPlayerInfo = Spring.GetPlayerInfo
local spGetAccountID = Spring.Utilities.GetAccountID

local gaiaTeamID = Spring.GetGaiaTeamID()
local defIDtoTranslatedHumanName = {}
local commanderDefIDs = {}

for _, def in ipairs(UnitDefs) do
    local humanName = def.translatedHumanName
    if humanName and humanName ~= "" then
        defIDtoTranslatedHumanName[def.id] = humanName
    end
    if def.customParams.iscommander then
        commanderDefIDs[def.id] = true
    end
end

-- Trusted powerusers (admins/mods/etc). Numeric keys are accountIDs, trustedNames is keyed by playername.
local powerusers = VFS.Include("luarules/configs/powerusers.lua")
local poweruserNames = powerusers.trustedNames or {}
local poweruserAccountIDs = {}
for key in pairs(powerusers) do
    if type(key) == "number" and key >= 0 then
        poweruserAccountIDs[key] = true
    end
end

-- Returns true if the unit's controlling player is a trusted poweruser.
local function isPoweruserUnit(unitID)
    local teamID = spGetUnitTeam(unitID)
    if not teamID then
        return false
    end
    local _, leaderPlayerID = spGetTeamInfo(teamID, false)
    if not leaderPlayerID or leaderPlayerID < 0 then
        return false
    end
    local accountID = spGetAccountID(leaderPlayerID)
    if accountID and accountID ~= -1 and poweruserAccountIDs[accountID] then
        return true
    end
    local name = spGetPlayerInfo(leaderPlayerID)
    if name and poweruserNames[name] then
        return true
    end
    return false
end

function widget:MapDrawCmd(playerID, type, x, y, z, label)
    -- This callin fires on every client for every player's ping (our own and
    -- remote ones). We rewrite both the same way: suppress the original blank
    -- marker (return true) and re-add a labeled one that is local-only and
    -- cosmetically attributed to the original pinger via playerID.
    --
    -- We deliberately never rebroadcast (localOnly is always true):
    --   * We cannot send a networked marker on another player's behalf, so we
    --     could not correctly attribute a broadcast for a remote ping anyway.
    --   * Every client already runs this rewrite independently, so broadcasting
    --     our own ping would draw a duplicate marker on all other clients.
    local localOnly = true

    if type == "point" and label == "" then
        local unitIDs = spGetUnitsInCylinder(x, z, scanDistance)

        if #unitIDs > 0 then
            for _, unitID in ipairs(unitIDs) do
                if spGetUnitTeam(unitID) ~= gaiaTeamID then
                    local unitDefID = spGetUnitDefID(unitID)
                    local humanName = defIDtoTranslatedHumanName[unitDefID]
                    if humanName then
                        if commanderDefIDs[unitDefID] and isPoweruserUnit(unitID) then
                            label = "giant noob"
                        else
                            local isAllied = spIsUnitAllied(unitID)
                            if isAllied then
                                label = "Allied " .. humanName
                            else
                                label = "Enemy " .. humanName
                            end
                        end

                        spMarkerAddPoint(x, y, z, label, localOnly, playerID)

                        return true
                    end
                end
            end
        else
            local closestMexSpot = WG['resource_spot_finder'].GetClosestMexSpot(x, z)
            local distanceSqr = math.distance2dSquared(x, z, closestMexSpot.x, closestMexSpot.z)
            if closestMexSpot and distanceSqr < scanDistance * scanDistance then
                label = "Mex Spot"
                spMarkerAddPoint(x, y, z, label, localOnly, playerID)
                return true
            end

            local featureIDs = spGetFeaturesInCylinder(x, z, scanDistance)
            for _, featureID in ipairs(featureIDs) do
                local featureDefID = Spring.GetFeatureDefID(featureID)
                local featureDef = FeatureDefs[featureDefID]

                if featureDef then
                    -- Check for geo points
                    if featureDef.geoThermal then
                        label = "Geo Vent"
                        spMarkerAddPoint(x, y, z, label, localOnly, playerID)
                        return true
                    end

                    -- Fall back to generic feature label
                    label = featureDef.translatedDescription or featureDef.name
                    spMarkerAddPoint(x, y, z, label, localOnly, playerID)
                    return true
                end
            end
        end
    end

    return false
end

function widget:GetConfigData()
    return {
        scanDistance = scanDistance
    }
end

function widget:SetConfigData(data)
    if data.scanDistance then
        scanDistance = data.scanDistance
    end
end

function widget:Initialize()
  WG['options'].addOptions({
    {
            id = "magic_ping_scan_distance",
            widgetname = "Magic Ping",
            name = "Scan Distance",
            type = "slider",
            value = scanDistance,
            min = 20,
            max = 500,
            step = 10,
            description = "Distance for magic ping scan",
            onchange = function (_, value)
                scanDistance = value
            end
        },
  })
end

function widget:Shutdown()
  WG['options'].removeOptions({
    "magic_ping_scan_distance",
  })
end
