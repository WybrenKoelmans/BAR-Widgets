

local widget = widget ---@type Widget

-- Track last 10 resurrected units
local resurrectedUnits = {}


local excludedAllyUnitTypes = {}

function widget:GetInfo()
    return {
        name = "Ressurected Find Ally",
        desc = "Resurrected units will find their ally who resurrected them or a building.",
        author = "uBdead",
        date = "2025-07-12",
        license = "GNU GPL, v2 or later",
        layer = 0, -- below most GUI elements, which generally go up to 10
        enabled = true
    }
end

function widget:Initialize()
    -- Initialize excluded ally unit types
    for defID, def in pairs(UnitDefs) do
        if def.canFly then
            excludedAllyUnitTypes[defID] = true -- Exclude all flying units
        end

        -- Exclude mines too
        if def.name and string.find(def.name:lower(), "mine") then
            excludedAllyUnitTypes[defID] = true
        end
    end

    -- Register the UnitCreated event
    widget:UnitCreated()
end

function widget:UnitCreated(unitID, unitDefID, unitTeam, builderID)
    -- Check if builderID exists and is a resurrection unit
    if builderID then
        local builderDefID = Spring.GetUnitDefID(builderID)
        if builderDefID and UnitDefs[builderDefID] and UnitDefs[builderDefID].canResurrect then
            -- This unit was resurrected
            Spring.Echo("Unit resurrected: " .. unitID .. " by ally: " .. unitTeam)

            -- If we resurrected a resurrection unit, let it guard the resurrector
            if UnitDefs[unitDefID].canResurrect then
                Spring.GiveOrderToUnit(unitID, CMD.GUARD, {builderID}, {})
                Spring.Echo("Resurrected unit is a resurrection unit, guarding the resurrector: " .. builderID)
                return
            end

            -- Find the closest ally unit that is not a resurrector or resurrected already
            local allyUnits = Spring.GetTeamUnits(unitTeam)
            local resurrectorDefIDs = {}
            -- Build a set of resurrector unitDefIDs for quick lookup
            for defID, def in pairs(UnitDefs) do
                if def.canResurrect then
                    resurrectorDefIDs[defID] = true
                end
            end

            local function isValidAlly(allyID)
                local allyDefID = Spring.GetUnitDefID(allyID)
                if not allyDefID then return false end

                -- Exclude ally units that are not of the correct type
                if excludedAllyUnitTypes[allyDefID] then return false end

                -- Exclude resurrectors
                if resurrectorDefIDs[allyDefID] then return false end

                -- Exclude self
                if allyID == unitID then return false end

                -- Exclude recently resurrected units
                for _, resID in ipairs(resurrectedUnits) do
                    if allyID == resID then return false end
                end
                return true
            end

            local x, y, z = Spring.GetUnitPosition(unitID)
            local closestAllyID = nil
            local closestDistance = math.huge
            for _, allyID in ipairs(allyUnits) do
                if isValidAlly(allyID) then
                    local ax, ay, az = Spring.GetUnitPosition(allyID)
                    if ax and az then
                        local dist = (x-ax)^2 + (z-az)^2
                        if dist < closestDistance then
                            closestDistance = dist
                            closestAllyID = allyID
                        end
                    end
                end
            end

            -- If a closest ally was found, you can do something with it
            if closestAllyID then
                Spring.Echo("Closest ally found: " .. closestAllyID .. " for resurrected unit: " .. unitID)
                -- Give a GUARD command from the resurrected unit to the closest ally
                Spring.GiveOrderToUnit(unitID, CMD.GUARD, {closestAllyID}, {})
            else
                Spring.Echo("No suitable ally found for resurrected unit: " .. unitID)
            end
            -- Track this resurrected unit
            table.insert(resurrectedUnits, unitID)
            if #resurrectedUnits > 100 then
                table.remove(resurrectedUnits, 1)
            end
        end
    end
end
