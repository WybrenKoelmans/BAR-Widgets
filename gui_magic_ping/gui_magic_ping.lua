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
local spMarkerErasePosition = Spring.MarkerErasePosition
local spGetSpectatingState = Spring.GetSpectatingState

local myPlayerID = Spring.GetMyPlayerID()
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

-- Work out the auto-label for a blank ping at (x, z). Returns nil when nothing
-- recognisable is nearby (in which case the blank ping is left untouched).
local function resolvePingLabel(x, z)
    local unitIDs = spGetUnitsInCylinder(x, z, scanDistance)
    if #unitIDs > 0 then
        for _, unitID in ipairs(unitIDs) do
            if spGetUnitTeam(unitID) ~= gaiaTeamID then
                local unitDefID = spGetUnitDefID(unitID)
                local humanName = defIDtoTranslatedHumanName[unitDefID]
                if humanName then
                    if commanderDefIDs[unitDefID] and isPoweruserUnit(unitID) then
                        return "giant noob"
                    elseif spGetSpectatingState() then
                        -- Spectators have no team, so allied/enemy is meaningless.
                        return humanName
                    elseif spIsUnitAllied(unitID) then
                        return "Allied " .. humanName
                    else
                        return "Enemy " .. humanName
                    end
                end
            end
        end
        return nil
    end

    local closestMexSpot = WG['resource_spot_finder'].GetClosestMexSpot(x, z)
    if closestMexSpot then
        local distanceSqr = math.distance2dSquared(x, z, closestMexSpot.x, closestMexSpot.z)
        if distanceSqr < scanDistance * scanDistance then
            return "Mex Spot"
        end
    end

    local featureIDs = spGetFeaturesInCylinder(x, z, scanDistance)
    for _, featureID in ipairs(featureIDs) do
        local featureDefID = Spring.GetFeatureDefID(featureID)
        local featureDef = FeatureDefs[featureDefID]
        if featureDef then
            if featureDef.geoThermal then
                return "Geo Vent"
            end
            return featureDef.translatedDescription or featureDef.name
        end
    end

    return nil
end

function widget:MapDrawCmd(playerID, type, x, y, z, label)
    -- Only auto-label blank point pings. Lines, erases and already-labeled pings
    -- (including our own broadcasts below, which re-enter with a non-empty label)
    -- pass straight through untouched.
    if type ~= "point" or label ~= "" then
        return false
    end

    local newLabel = resolvePingLabel(x, z)
    if not newLabel then
        return false
    end

    if playerID == myPlayerID then
        -- Our own ping: broadcast the labeled marker so EVERY player sees it
        -- (including those without this widget), correctly attributed to us over
        -- the network. The original blank ping was already networked before this
        -- callin ran and return-true only hides it locally, so we erase it
        -- network-wide first to avoid leaving a duplicate on other clients. That
        -- erase also clears the local relabel that other widget users add below.
        spMarkerErasePosition(x, y, z)
        spMarkerAddPoint(x, y, z, newLabel, false)
    else
        -- Someone else's ping: relabel locally only, cosmetically attributed to
        -- the original pinger. We cannot broadcast on their behalf. If they also
        -- run this widget, their own broadcast (plus erase) supersedes this copy.
        spMarkerAddPoint(x, y, z, newLabel, true, playerID)
    end

    return true
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
