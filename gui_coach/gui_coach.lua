
local fontSize = 16 -- default font size, can be changed by options slider
local fontSizeSubtext = 12
local fontSizeMin = 9
local fontSizeMax = 64
local fontSizeStep = 1

local widget = widget ---@type Widget

function widget:GetInfo()
    return {
        name = "Coach",
        desc = "Gives a list of things you should probably do to play well.",
        author = "uBdead",
        date = "2025-07-17",
        license = "GNU GPL, v2 or later",
        layer = 0,
        enabled = true
    }
end

-- Precompute builder and commander tables for efficiency (like unit_builder_priority.lua)
local unitIsBuilder = {}
local unitIsCommander = {}
for udefID, def in ipairs(UnitDefs) do
    if def.isBuilder and not def.isBuilding then
        unitIsBuilder[udefID] = true
        if def.customParams and def.customParams.iscommander then
            unitIsCommander[udefID] = true
        end
    end
end

-- OpenGL functions for drawing
local gl = gl

local metalNearStart = -1
local cooldownLeft = 1 -- in seconds
local refreshRate = 1  -- in seconds

local metalExtractors = 0
local metalExtractorsUnderConstruction = 0
local metalCurrent, metalStorage, metalPull, metalIncome, metalExpense, metalReclaim, metalSent, metalReceived, metalShare, metalSent, metalReceived, metalExcess
local energyCurrent, energyStorage, energyPull, energyIncome, energyExpense, energyReclaim, energySent, energyReceived, energyShare, energySent, energyReceived, energyExcess
local metalPercentage = 0
local energyPercentage = 0
local energyIncomeRecords = {}
local energyIncomeAverage = 0

local factories = 0
local cbots = 0
local commanderIdle = true
local constructorsIdle = 0
local factoryIdle = false
local pausedFactory = false
local turrets = 0
local radars = 0
local buildPower = 0
local armyStrength = 0
local ecoSize = 0

-- Accurate average wind calculation (copied from gui_top_bar.lua)
local minWind = Game.windMin
local maxWind = Game.windMax
local function GetAverageWind()
    -- Precomputed average wind values from monte carlo simulation
    local avgWind = {
        [0] = { [1] = 0.8, [2] = 1.5, [3] = 2.2, [4] = 3.0, [5] = 3.7, [6] = 4.5, [7] = 5.2, [8] = 6.0, [9] = 6.7, [10] = 7.5, [11] = 8.2, [12] = 9.0, [13] = 9.7, [14] = 10.4, [15] = 11.2, [16] = 11.9, [17] = 12.7, [18] = 13.4, [19] = 14.2, [20] = 14.9, [21] = 15.7, [22] = 16.4, [23] = 17.2, [24] = 17.9, [25] = 18.6, [26] = 19.2, [27] = 19.6, [28] = 20.0, [29] = 20.4, [30] = 20.7 },
        [1] = { [2] = 1.6, [3] = 2.3, [4] = 3.0, [5] = 3.8, [6] = 4.5, [7] = 5.2, [8] = 6.0, [9] = 6.7, [10] = 7.5, [11] = 8.2, [12] = 9.0, [13] = 9.7, [14] = 10.4, [15] = 11.2, [16] = 11.9, [17] = 12.7, [18] = 13.4, [19] = 14.2, [20] = 14.9, [21] = 15.7, [22] = 16.4, [23] = 17.2, [24] = 17.9, [25] = 18.6, [26] = 19.2, [27] = 19.6, [28] = 20.0, [29] = 20.4, [30] = 20.7 },
        [2] = { [3] = 2.6, [4] = 3.2, [5] = 3.9, [6] = 4.6, [7] = 5.3, [8] = 6.0, [9] = 6.8, [10] = 7.5, [11] = 8.2, [12] = 9.0, [13] = 9.7, [14] = 10.5, [15] = 11.2, [16] = 12.0, [17] = 12.7, [18] = 13.4, [19] = 14.2, [20] = 14.9, [21] = 15.7, [22] = 16.4, [23] = 17.2, [24] = 17.9, [25] = 18.6, [26] = 19.2, [27] = 19.6, [28] = 20.0, [29] = 20.4, [30] = 20.7 },
        [3] = { [4] = 3.6, [5] = 4.2, [6] = 4.8, [7] = 5.5, [8] = 6.2, [9] = 6.9, [10] = 7.6, [11] = 8.3, [12] = 9.0, [13] = 9.8, [14] = 10.5, [15] = 11.2, [16] = 12.0, [17] = 12.7, [18] = 13.5, [19] = 14.2, [20] = 15.0, [21] = 15.7, [22] = 16.4, [23] = 17.2, [24] = 17.9, [25] = 18.7, [26] = 19.2, [27] = 19.7, [28] = 20.0, [29] = 20.4, [30] = 20.7 },
        [4] = { [5] = 4.6, [6] = 5.2, [7] = 5.8, [8] = 6.4, [9] = 7.1, [10] = 7.8, [11] = 8.5, [12] = 9.2, [13] = 9.9, [14] = 10.6, [15] = 11.3, [16] = 12.1, [17] = 12.8, [18] = 13.5, [19] = 14.3, [20] = 15.0, [21] = 15.7, [22] = 16.5, [23] = 17.2, [24] = 18.0, [25] = 18.7, [26] = 19.2, [27] = 19.7, [28] = 20.1, [29] = 20.4, [30] = 20.7 },
        [5] = { [6] = 5.5, [7] = 6.1, [8] = 6.8, [9] = 7.4, [10] = 8.0, [11] = 8.7, [12] = 9.4, [13] = 10.1, [14] = 10.8, [15] = 11.5, [16] = 12.2, [17] = 12.9, [18] = 13.6, [19] = 14.4, [20] = 15.1, [21] = 15.8, [22] = 16.5, [23] = 17.3, [24] = 18.0, [25] = 18.8, [26] = 19.3, [27] = 19.7, [28] = 20.1, [29] = 20.4, [30] = 20.7 },
        [6] = { [7] = 6.5, [8] = 7.1, [9] = 7.7, [10] = 8.4, [11] = 9.0, [12] = 9.7, [13] = 10.3, [14] = 11.0, [15] = 11.7, [16] = 12.4, [17] = 13.1, [18] = 13.8, [19] = 14.5, [20] = 15.2, [21] = 15.9, [22] = 16.7, [23] = 17.4, [24] = 18.1, [25] = 18.8, [26] = 19.4, [27] = 19.8, [28] = 20.2, [29] = 20.5, [30] = 20.8 },
        [7] = { [8] = 7.5, [9] = 8.1, [10] = 8.7, [11] = 9.3, [12] = 10.0, [13] = 10.6, [14] = 11.3, [15] = 11.9, [16] = 12.6, [17] = 13.3, [18] = 14.0, [19] = 14.7, [20] = 15.4, [21] = 16.1, [22] = 16.8, [23] = 17.5, [24] = 18.2, [25] = 19.0, [26] = 19.5, [27] = 19.9, [28] = 20.3, [29] = 20.6, [30] = 20.9 },
        [8] = { [9] = 8.5, [10] = 9.1, [11] = 9.7, [12] = 10.3, [13] = 11.0, [14] = 11.6, [15] = 12.2, [16] = 12.9, [17] = 13.6, [18] = 14.2, [19] = 14.9, [20] = 15.6, [21] = 16.3, [22] = 17.0, [23] = 17.7, [24] = 18.4, [25] = 19.1, [26] = 19.6, [27] = 20.0, [28] = 20.4, [29] = 20.7, [30] = 21.0 },
        [9] = { [10] = 9.5, [11] = 10.1, [12] = 10.7, [13] = 11.3, [14] = 11.9, [15] = 12.6, [16] = 13.2, [17] = 13.8, [18] = 14.5, [19] = 15.2, [20] = 15.8, [21] = 16.5, [22] = 17.2, [23] = 17.9, [24] = 18.6, [25] = 19.3, [26] = 19.8, [27] = 20.2, [28] = 20.5, [29] = 20.8, [30] = 21.1 },
        [10] = { [11] = 10.5, [12] = 11.1, [13] = 11.7, [14] = 12.3, [15] = 12.9, [16] = 13.5, [17] = 14.2, [18] = 14.8, [19] = 15.4, [20] = 16.1, [21] = 16.8, [22] = 17.4, [23] = 18.1, [24] = 18.8, [25] = 19.5, [26] = 20.0, [27] = 20.4, [28] = 20.7, [29] = 21.0, [30] = 21.2 },
        [11] = { [12] = 11.5, [13] = 12.1, [14] = 12.7, [15] = 13.3, [16] = 13.9, [17] = 14.5, [18] = 15.1, [19] = 15.8, [20] = 16.4, [21] = 17.1, [22] = 17.7, [23] = 18.4, [24] = 19.1, [25] = 19.7, [26] = 20.2, [27] = 20.6, [28] = 20.9, [29] = 21.2, [30] = 21.4 },
        [12] = { [13] = 12.5, [14] = 13.1, [15] = 13.6, [16] = 14.2, [17] = 14.9, [18] = 15.5, [19] = 16.1, [20] = 16.7, [21] = 17.4, [22] = 18.0, [23] = 18.7, [24] = 19.3, [25] = 20.0, [26] = 20.4, [27] = 20.8, [28] = 21.1, [29] = 21.4, [30] = 21.6 },
        [13] = { [14] = 13.5, [15] = 14.1, [16] = 14.6, [17] = 15.2, [18] = 15.8, [19] = 16.5, [20] = 17.1, [21] = 17.7, [22] = 18.4, [23] = 19.0, [24] = 19.6, [25] = 20.3, [26] = 20.7, [27] = 21.1, [28] = 21.4, [29] = 21.6, [30] = 21.8 },
        [14] = { [15] = 14.5, [16] = 15.0, [17] = 15.6, [18] = 16.2, [19] = 16.8, [20] = 17.4, [21] = 18.1, [22] = 18.7, [23] = 19.3, [24] = 20.0, [25] = 20.6, [26] = 21.0, [27] = 21.3, [28] = 21.6, [29] = 21.8, [30] = 22.0 },
        [15] = { [16] = 15.5, [17] = 16.0, [18] = 16.6, [19] = 17.2, [20] = 17.8, [21] = 18.4, [22] = 19.0, [23] = 19.6, [24] = 20.3, [25] = 20.9, [26] = 21.3, [27] = 21.6, [28] = 21.9, [29] = 22.1, [30] = 22.3 },
        [16] = { [17] = 16.5, [18] = 17.0, [19] = 17.6, [20] = 18.2, [21] = 18.8, [22] = 19.4, [23] = 20.0, [24] = 20.6, [25] = 21.3, [26] = 21.7, [27] = 21.9, [28] = 22.2, [29] = 22.4, [30] = 22.5 },
        [17] = { [18] = 17.5, [19] = 18.0, [20] = 18.6, [21] = 19.2, [22] = 19.8, [23] = 20.4, [24] = 21.0, [25] = 21.6, [26] = 22.0, [27] = 22.3, [28] = 22.5, [29] = 22.7, [30] = 22.8 },
        [18] = { [19] = 18.5, [20] = 19.0, [21] = 19.6, [22] = 20.2, [23] = 20.8, [24] = 21.4, [25] = 22.0, [26] = 22.4, [27] = 22.6, [28] = 22.8, [29] = 23.0, [30] = 23.1 },
        [19] = { [20] = 19.5, [21] = 20.0, [22] = 20.6, [23] = 21.2, [24] = 21.8, [25] = 22.4, [26] = 22.7, [27] = 22.9, [28] = 23.1, [29] = 23.2, [30] = 23.4 },
        [20] = { [21] = 20.4, [22] = 21.0, [23] = 21.6, [24] = 22.2, [25] = 22.8, [26] = 23.1, [27] = 23.3, [28] = 23.4, [29] = 23.6, [30] = 23.7 },
        [21] = { [22] = 21.4, [23] = 22.0, [24] = 22.6, [25] = 23.2, [26] = 23.5, [27] = 23.6, [28] = 23.8, [29] = 23.9, [30] = 24.0 },
        [22] = { [23] = 22.4, [24] = 23.0, [25] = 23.6, [26] = 23.8, [27] = 24.0, [28] = 24.1, [29] = 24.2, [30] = 24.2 },
        [23] = { [24] = 23.4, [25] = 24.0, [26] = 24.2, [27] = 24.4, [28] = 24.4, [29] = 24.5, [30] = 24.5 },
        [24] = { [25] = 24.4, [26] = 24.6, [27] = 24.7, [28] = 24.7, [29] = 24.8, [30] = 24.8 },
    }
    if avgWind[minWind] and avgWind[minWind][maxWind] then
        return avgWind[minWind][maxWind]
    end
    -- fallback approximation
    return math.max(minWind, maxWind * 0.75)
end

local averageWind = GetAverageWind()

-- Table to hold todo items with priorities
local todoList = {}
local todoItems = {}

-- Function to determine unitpic based on todo text
local function GetUnitPicForTodo(todoText)
    -- Check for specific patterns first (more specific matches)
    if string.find(todoText, "Wind Turbine") then
        return "armwin.dds"
    elseif string.find(todoText, "Solar Panel") then
        return "armsolar.dds"
    elseif string.find(todoText, "Metal Extractor") then
        return "armmex.dds"
    elseif string.find(todoText, "Factory") then
        return "armlab.dds"
    elseif string.find(todoText, "Constructor") then
        return "armca.dds"
    elseif string.find(todoText, "Radar") then
        return "armrad.dds"
    elseif string.find(todoText, "turret") then
        return "armllt.dds"
    elseif string.find(todoText, "Energy Storage") then
        return "armestor.dds"
    elseif string.find(todoText, "Converter") then
        return "armmakr.dds"
    elseif string.find(todoText, "Commander") then
        return "armcom.dds"
    elseif string.find(todoText, "Army") then
        return "armpw.dds"
    elseif string.find(todoText, "Build Power") or string.find(todoText, "assist") or string.find(todoText, "Spend") then
        return "armca.dds"
    elseif string.find(todoText, "Energy") then
        return "armsolar.dds"
    elseif string.find(todoText, "Metal") or string.find(todoText, "Stalling Metal") then
        return "armmex.dds"
    elseif string.find(todoText, "idle") then
        return "armcom.dds"
    elseif string.find(todoText, "paused") then
        return "armlab.dds"
    end
    
    return nil -- no specific unitpic found
end

-- Add a todo item with a given priority and optional subtext (lower number = higher priority)
function AddTodo(item, priority, subtext, unitpic)
    if not unitpic then
        unitpic = GetUnitPicForTodo(item)
    end
    table.insert(todoList, { text = item, priority = priority or 100, subtext = subtext, unitpic = unitpic })
end

-- Sort todoList by priority (ascending)
local function SortTodoList()
    table.sort(todoList, function(a, b) return a.priority < b.priority end)
end


-- Get a list of todo items (table with text and subtext), sorted by priority
local function GetTodoItems()
    SortTodoList()
    local items = {}
    for _, entry in ipairs(todoList) do
        table.insert(items, { text = entry.text, subtext = entry.subtext, priority = entry.priority, unitpic = entry.unitpic })
    end
    return items
end


local function GetCommanderPosition()
    local myTeamID = Spring.GetMyTeamID()
    local myUnits = Spring.GetTeamUnits(myTeamID)
    for i = 1, #myUnits do
        local unitID = myUnits[i]
        local unitDefID = Spring.GetUnitDefID(unitID)
        if unitDefID then
            local ud = UnitDefs[unitDefID]
            if ud and ud.customParams and ud.customParams.iscommander then
                return Spring.GetUnitPosition(unitID)
            end
        end
    end
    -- fallback: just use first unit if no commander found
    if #myUnits > 0 then
        return Spring.GetUnitPosition(myUnits[1])
    end
    return nil, nil, nil
end

local function CountMetalSpotsNearby(x, z, radius)
    if not WG.resource_spot_finder or not WG.resource_spot_finder.metalSpotsList then
        return 0
    end
    local count = 0
    for i, spot in ipairs(WG.resource_spot_finder.metalSpotsList) do
        local dx = x - spot.x
        local dz = z - spot.z
        if (dx * dx + dz * dz) <= (radius * radius) then
            count = count + 1
        end
    end
    return count
end

function widget:Update(dt)
    -- Spring.Echo("Coach Update: dt = " .. dt)
    cooldownLeft = cooldownLeft - dt
    if cooldownLeft > 0 then
        -- Spring.Echo("Coach Update: cooldown left = " .. cooldownLeft)
        return
    end
    cooldownLeft = refreshRate

    -- Clear todoList for this update
    todoList = {}

    doChecks()

    todoItems = GetTodoItems()
end

function doChecks()
    if Spring.GetGameFrame() <= 0 then
        -- Game has not started yet, no checks needed
        return
    end

    if (metalNearStart == -1 and Spring.GetGameFrame() > 0) then
        local x, _, z = GetCommanderPosition()
        if x and z then
            metalNearStart = CountMetalSpotsNearby(x, z, 600)
            -- Spring.Echo("Found " .. metalNearStart .. " metal spots nearby.")
        else
            metalNearStart = 0
            -- Spring.Echo("No commander found, cannot determine nearby metal spots.")
        end
    end

    -- Check the buildings we currently have
    local myTeamID = Spring.GetMyTeamID()
    local myUnits = Spring.GetTeamUnits(myTeamID)
    metalExtractors = 0
    metalExtractorsUnderConstruction = 0
    metalCurrent, metalStorage, metalPull, metalIncome, metalExpense, metalReclaim, metalSent, metalReceived, metalShare, metalSent, metalReceived, metalExcess =
    Spring.GetTeamResources(myTeamID,
        "metal")
    energyCurrent, energyStorage, energyPull, energyIncome, energyExpense, energyReclaim, energySent, energyReceived, energyShare, energySent, energyReceived, energyExcess =
    Spring.GetTeamResources(myTeamID,
        "energy")
    metalPercentage = metalCurrent / (metalStorage + 1)    -- avoid division by zero
    energyPercentage = energyCurrent / (energyStorage + 1) -- avoid division by zero
    factories = 0
    cbots = 0
    commanderIdle = true
    constructorsIdle = 0
    factoryIdle = false
    pausedFactory = false
    turrets = 0
    radars = 0
    buildPower = 0
    armyStrength = 0
    ecoSize = 0

    -- Calculate average energy income over the last 10 seconds
    energyIncomeRecords[#energyIncomeRecords + 1] = energyIncome
    if #energyIncomeRecords > 10 then
        table.remove(energyIncomeRecords, 1) -- keep only the last 10 records
    end
    if #energyIncomeRecords > 0 then
        local sum = 0
        for _, income in ipairs(energyIncomeRecords) do
            sum = sum + income
        end
        energyIncomeAverage = sum / #energyIncomeRecords
    else
        energyIncomeAverage = 0
    end

    for i = 1, #myUnits do
        local unitID = myUnits[i]
        local unitDefID = Spring.GetUnitDefID(unitID)
        if unitDefID then
            local ud = UnitDefs[unitDefID]
            local uh = { Spring.GetUnitHealth(unitID) }
            if ud then
                -- Check for metal extractor (mex)
                if ud.extractsMetal and ud.extractsMetal > 0 then
                    if uh[5] and uh[5] == 1 then
                        metalExtractors = metalExtractors + 1
                    else
                        metalExtractorsUnderConstruction = metalExtractorsUnderConstruction + 1
                    end
                end
                -- Check for factories
                if ud.isFactory and uh[5] and uh[5] == 1 then
                    factories = factories + 1
                    -- Check if factory is idle using GetFactoryCommands (best practice)
                    local queue = Spring.GetFactoryCommands(unitID, 1)
                    -- get the table size of t
                    if type(queue) == "table" and #queue == 0 and metalCurrent > 250 and energyCurrent > 500 then
                        factoryIdle = true
                    end
                    -- Check if factory is paused (first command is CMD.WAIT)
                    if type(queue) == "table" and #queue > 0 and queue[1].id == CMD.WAIT then
                        pausedFactory = true
                    end
                end

                -- Spring.Echo("Unit ID: " .. ud.name .. " Health: " .. (uh[1] or 0))
                -- Check for construction bots (exclude commander)
                if unitIsBuilder[unitDefID] and not unitIsCommander[unitDefID] then
                    cbots = cbots + 1

                    -- Check if constructor is idle
                    if Spring.GetUnitCommandCount(unitID) == 0 then
                        constructorsIdle = constructorsIdle + 1
                    end
                end
                -- Check if commander is idle
                if unitIsCommander[unitDefID] then
                    commanderIdle = Spring.GetUnitCommandCount(unitID) == 0
                end

                -- check for turrets
                if ud.isBuilding and ud.canAttack and not ud.isFactory then
                    turrets = turrets + 1
                end

                -- check for radars
                if ud.isBuilding and ud.radarRadius > 0 then
                    radars = radars + 1
                end

                if ud.buildSpeed and ud.buildSpeed > 0 then
                    buildPower = buildPower + ud.buildSpeed
                end

                -- Army strength calculation: sum up HP of all non-builder, non-structure units that can attack
                if not unitIsBuilder[unitDefID] 
                    and not ud.isBuilding
                    and ud.canAttack
                    and uh[1] and uh[5] and uh[5] == 1 then
                    armyStrength = armyStrength + uh[1]
                else
                    -- Eco size calculation: sum up HP of all builders and structures
                    if unitIsBuilder[unitDefID] or ud.isBuilding then
                        ecoSize = ecoSize + uh[1]
                    end
                end
            end
        end
    end

    -- Spring.Echo("Build power: " .. buildPower)

    if energyCurrent < 100 then
        local _, _, _, windStrength = Spring.GetWind()
        if windStrength > 6 then
            AddTodo("Build a Wind Turbine", 5,
                "You are energy stalling! Pause all other construction (including factories) and focus on energy production.")
        else
            AddTodo("Build a Solar Panel", 5,
                "You are energy stalling! Pause all other construction (including factories) and focus on energy production.")
        end
    end

    if metalCurrent < 20 then
        AddTodo("Stalling Metal, try to conquer Metal Spots, reclaim battlefield, or build cheaper units.", 5,
            "You need to make sure army size does not suffer too much!")
    end

    local ecoSetupDone = false
    if (averageWind and averageWind > 6) then
        if (metalExtractors < math.min(2, metalNearStart)) then
            AddTodo("Build " .. (math.min(2, metalNearStart) - metalExtractors) .. " more Metal Extractors", 10,
                "They generate resources the slowest, so you need them early.")
        elseif (energyIncomeAverage < 14 + 25 and energyCurrent < 500) then
            AddTodo("Build a Wind Turbine", 10,
                "You need sufficient energy production to build the next Metal Extractor and your Factory.")
        elseif metalExtractors < metalNearStart then
            AddTodo("Build " .. (metalNearStart - metalExtractors) .. " more Metal Extractors", 10,
                "Gaining early metal is crucial for your economy.")
        else
            ecoSetupDone = true
        end
    else
        -- TODO
        -- low winds on this map, better to build solar panels
        if (metalExtractors < math.min(3, metalNearStart)) then
            AddTodo("Build " .. (math.min(3, metalNearStart) - metalExtractors) .. " more Metal Extractors", 10,
                "They generate resources the slowest, so you need them early.")
        end
    end

    if not ecoSetupDone then
        return
    end

    if commanderIdle then
        local buildingCandidate = getCommanderBuildingCandidate()
        if buildingCandidate then
            AddTodo(buildingCandidate.text, buildingCandidate.priority, buildingCandidate.subtext)
        else
            AddTodo("Commander is idle", 90,
                "You should give it orders to build, assist, reclaim, or move it tactically.")
        end
    end

    if constructorsIdle > 0 then
        AddTodo("Constructor is idle", 99 - constructorsIdle * 5,
            "You should give it orders to build, assist, or reclaim.")
    end

    if factoryIdle then
        AddTodo("Factory is idle", 90,
            "You should give it orders to build units or assign a constructor to assist it.")
    end

    if pausedFactory and metalPercentage > 0.5 and energyPercentage > 0.5 then
        AddTodo("Factory is paused", 90,
            "You should unpause it to continue producing units.")
    end

    local armyToEcoRatio = getArmyToEcoRatio()

    if factories < 1 then
        AddTodo("Build a Factory", 10, "You need a Factory to produce more advanced units and structures.")
    elseif cbots < 2 then
        AddTodo("Build a Constructor in the Factory", 10, "Early game expansion is crucial.")
        if energyCurrent > 500 then
            AddTodo(
                "You have enough energy to boost building the Constructor, assign the Commander to assist the Factory.",
                11,
                "This will speed up the production of the Constructor.")
        end
    elseif cbots == 2 and metalExtractors < 6 and metalExtractorsUnderConstruction == 0 then
        AddTodo("Assign the Constructor to build up all the closest metal spots.",
            12,
            "You need to expand your economy quickly. Use the Constructor to build Metal Extractors on nearby metal spots.")
    elseif armyToEcoRatio > 1 then
        local buildPowerMetalRatio = buildPower / (metalIncome + 1)   -- avoid division by zero
        local buildPowerEnergyRatio = buildPower / (energyIncomeAverage + 1) -- avoid division by zero

        if (energyPercentage > 0.95 and metalPercentage > 0.5 and buildPowerMetalRatio < 30) or buildPowerMetalRatio < 40 and buildPowerEnergyRatio < 1 then
            AddTodo("Add Build Power", 70,
                "Build Constructors to add build power to keep scaling your economy.")
        end
        if (energyIncomeAverage / (energyStorage + 1) > 0.5) then
            AddTodo("Build an Energy Storage", 99,
                "You have low energy storage. Consider building an Energy Storage to store excess energy.")
        else
            AddTodo("Build more Energy", 99,
                "You have enough metal production but not enough energy production. Consider building more Energy Plants.")
        end

        if armyToEcoRatio > 2 then
            AddTodo("Pause Factories: Your army is much larger than your economy.", 50,
                "Divert build power from factories to economy construction.")
        elseif armyToEcoRatio > 1.5 then
            AddTodo("Redirect Factory Build Power to the Economy.", 60,
                "Your army is outpacing your economy.")
        end
    else
        -- Eco is outpacing the army size, so we should build more army
        AddTodo("Build more Army", 70,
            "Your economy is outpacing your army size. Assign more Build Power to factories to produce more units.")
    end

    if shouldBuildConverter() then -- building a converter can be also fine to do while building army
        AddTodo("Build a Converter", 99,
            "You have a lot of energy production but not enough metal. Consider building a Converter to convert energy to metal.")
    end

    -- if we are wasting metal, we should invest assist Factories or build a big project
    if metalPercentage > 0.25 and energyPercentage > 0.75 then
        AddTodo("Spend more Build Power", 10,
            "You have excess metal and energy. Build more expensive units or add more Build Power.")
    end
end

function shouldBuildConverter()
    local energyIncomeToOutcomeRatio = energyExpense / (energyIncomeAverage + 1) -- avoid division by zeros
    local energyIncomeToOutcomeThreshold = 0.8                            -- typical good ratio in BAR
    -- Spring.Echo("Energy Income to Outcome Ratio: " .. energyIncomeToOutcomeRatio)
    if energyIncomeToOutcomeRatio < energyIncomeToOutcomeThreshold and energyPercentage > 0.90 then
        return true
    end

    return false
end

function getArmyToEcoRatio()
    -- check if the army strength is in ratio to the economy
    local armyToEcoRatio = armyStrength / (ecoSize + 1) -- avoid division by zero

    -- Spring.Echo("Army Strength: " .. armyStrength .. ", Eco Size: " .. ecoSize .. ", Ratio: " .. armyToEcoRatio)

    return armyToEcoRatio
end

function widget:DrawScreen()
    local vsx, vsy = gl.GetViewSizes()
    local x = vsx * 0.5 -- 50% from the left
    local y = vsy * 0.9 -- 10% from the top
    local xOffset = 0
    local iconSize = fontSize * 2 -- icon scales with font size
    local iconPadding = math.floor(fontSize * 0.5) -- space between icon and text

    -- calculate the offset based on the text width (including subtext if present)
    for _, item in ipairs(todoItems) do
        local mainText = "• " .. item.text
        local textWidth = gl.GetTextWidth(mainText) * fontSize
        if item.subtext then
            local subWidth = gl.GetTextWidth(item.subtext) * fontSizeSubtext
            if subWidth > textWidth then
                textWidth = subWidth
            end
        end
        -- Add space for icon if present
        if item.unitpic then
            textWidth = textWidth + iconSize + iconPadding
        end
        if textWidth > xOffset then
            xOffset = textWidth
        end
    end
    x = x - xOffset / 2      -- center the text horizontally

    local itemSpacing = fontSize * 2.75   -- vertical space between top-level items
    local subtextOffset = fontSize * 1.1 -- small offset for subtext, close to main text

    for i, item in ipairs(todoItems) do
        local baseY = y - (i - 1) * itemSpacing
        local currentX = x

        -- Draw unit icon if available
        if item.unitpic then
            gl.Color(1, 1, 1, 1) -- reset color
            gl.Texture("unitpics/" .. item.unitpic)
            gl.TexRect(currentX, baseY - iconSize/2, currentX + iconSize, baseY + iconSize/2)
            gl.Texture(false) -- disable texture
            currentX = currentX + iconSize + iconPadding
        end

        -- Draw text
        gl.Text("• " .. item.text, currentX, baseY, fontSize, "o")
        if item.subtext then
            gl.Text(item.subtext, currentX + fontSize + 8, baseY - subtextOffset, fontSizeSubtext, "o")
        end
    end
end

function widget:Initialize()
    -- Register font size option with WG.options if available
    if WG.options and WG.options.addOption then
        WG.options.addOption({
            widgetname = "Coach",
            id = "coach_fontsize",
            group = "custom",
            category = 2,
            name = "Font Size",
            type = "slider",
            min = fontSizeMin,
            max = fontSizeMax,
            step = fontSizeStep,
            value = fontSize,
            description = "Adjust the font size for the Coach todo list.",
            onchange = function(_, value)
                fontSize = tonumber(value)
                fontSizeSubtext = math.floor(fontSize * 0.75)
            end
        })
    end
end

function getCommanderBuildingCandidate()
    if radars < 1 then
        return {
            text = "Build a Radar",
            priority = 80,
            subtext =
            "You have no radars. Consider building one for better map awareness."
        }
    end
    if turrets < 3 then
        return {
            text = "Build a turret",
            priority = 80,
            subtext =
            "You have few turrets. Consider building one for defense."
        }
    end
    return nil
end
