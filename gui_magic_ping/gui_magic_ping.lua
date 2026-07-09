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

local gaiaTeamID = Spring.GetGaiaTeamID()
local defIDtoTranslatedHumanName = {}
for _, def in ipairs(UnitDefs) do
    local humanName = def.translatedHumanName
    if humanName and humanName ~= "" then
        defIDtoTranslatedHumanName[def.id] = humanName
    end
end


function widget:MapDrawCmd(playerID, type, x, y, z, label)
    if label == "" then
        local unitIDs = spGetUnitsInCylinder(x, z, scanDistance)

        if #unitIDs > 0 then
            for _, unitID in ipairs(unitIDs) do
                if spGetUnitTeam(unitID) ~= gaiaTeamID then
                    local unitDefID = spGetUnitDefID(unitID)
                    local humanName = defIDtoTranslatedHumanName[unitDefID]
                    if humanName then
                        local isAllied = spIsUnitAllied(unitID)
                        if isAllied then
                            label = "Allied " .. humanName
                        else
                            label = "Enemy " .. humanName
                        end

                        spMarkerAddPoint(x, y, z, label)

                        return true
                    end
                end
            end
        else
            local closestMexSpot = WG['resource_spot_finder'].GetClosestMexSpot(x, z)
            local distanceSqr = math.distance2dSquared(x, z, closestMexSpot.x, closestMexSpot.z)
            if closestMexSpot and distanceSqr < scanDistance * scanDistance then
                label = "Mex Spot"
                spMarkerAddPoint(x, y, z, label)
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
                        spMarkerAddPoint(x, y, z, label)
                        return true
                    end

                    -- Fall back to generic feature label
                    label = featureDef.translatedDescription or featureDef.name
                    spMarkerAddPoint(x, y, z, label)
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
