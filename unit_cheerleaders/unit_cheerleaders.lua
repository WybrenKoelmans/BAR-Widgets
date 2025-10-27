
local widget = widget ---@type Widget
local spGetMouseState = Spring.GetMouseState
local spTraceScreenRay = Spring.TraceScreenRay
local spGetSelectedUnits = Spring.GetSelectedUnits
local spGetUnitDefID = Spring.GetUnitDefID
local spGiveOrderToUnit = Spring.GiveOrderToUnit
local CMD_MOVE = CMD.MOVE

function widget:GetInfo()
    return {
        name = "Cheerleaders",
        desc = "Your units have become aware of the 4th dimension and are trying to communicate",
        author = "uBdead",
        date = "Oct 2025",
        license = "GNU GPL, v2 or later",
        layer = 0, -- below most GUI elements, which generally go up to 10
        enabled = true,
		handler = true,
    }
end

-- Simple 5x7 bitmap font definition (only A-Z, space for demo)
local font5x7 = {
    ["A"] = {
        "  X  ",
        " X X ",
        "X   X",
        "XXXXX",
        "X   X",
        "X   X",
        "X   X",
    },
    ["B"] = {
        "XXXX ",
        "X   X",
        "X   X",
        "XXXX ",
        "X   X",
        "X   X",
        "XXXX ",
    },
    ["C"] = {
        " XXXX",
        "X    ",
        "X    ",
        "X    ",
        "X    ",
        "X    ",
        " XXXX",
    },
    ["D"] = {
        "XXXX ",
        "X   X",
        "X   X",
        "X   X",
        "X   X",
        "X   X",
        "XXXX ",
    },
    ["E"] = {
        "XXXXX",
        "X    ",
        "X    ",
        "XXXX ",
        "X    ",
        "X    ",
        "XXXXX",
    },
    ["F"] = {
        "XXXXX",
        "X    ",
        "X    ",
        "XXXX ",
        "X    ",
        "X    ",
        "X    ",
    },
    ["G"] = {
        " XXXX",
        "X    ",
        "X    ",
        "X  XX",
        "X   X",
        "X   X",
        " XXXX",
    },
    ["H"] = {
        "X   X",
        "X   X",
        "X   X",
        "XXXXX",
        "X   X",
        "X   X",
        "X   X",
    },
    ["I"] = {
        "XXXXX",
        "  X  ",
        "  X  ",
        "  X  ",
        "  X  ",
        "  X  ",
        "XXXXX",
    },
    ["J"] = {
        "XXXXX",
        "    X",
        "    X",
        "    X",
        "    X",
        "X   X",
        " XXX ",
    },
    ["K"] = {
        "X   X",
        "X  X ",
        "X X  ",
        "XX   ",
        "X X  ",
        "X  X ",
        "X   X",
    },
    ["L"] = {
        "X    ",
        "X    ",
        "X    ",
        "X    ",
        "X    ",
        "X    ",
        "XXXXX",
    },
    ["M"] = {
        "X   X",
        "XX XX",
        "X X X",
        "X   X",
        "X   X",
        "X   X",
        "X   X",
    },
    ["N"] = {
        "X   X",
        "XX  X",
        "X X X",
        "X  XX",
        "X   X",
        "X   X",
        "X   X",
    },
    ["O"] = {
        " XXX ",
        "X   X",
        "X   X",
        "X   X",
        "X   X",
        "X   X",
        " XXX ",
    },
    ["P"] = {
        "XXXX ",
        "X   X",
        "X   X",
        "XXXX ",
        "X    ",
        "X    ",
        "X    ",
    },
    ["Q"] = {
        " XXX ",
        "X   X",
        "X   X",
        "X   X",
        "X X X",
        "X  X ",
        " XX X",
    },
    ["R"] = {
        "XXXX ",
        "X   X",
        "X   X",
        "XXXX ",
        "X X  ",
        "X  X ",
        "X   X",
    },
    ["S"] = {
        " XXXX",
        "X    ",
        "X    ",
        " XXX ",
        "    X",
        "    X",
        "XXXX ",
    },
    ["T"] = {
        "XXXXX",
        "  X  ",
        "  X  ",
        "  X  ",
        "  X  ",
        "  X  ",
        "  X  ",
    },
    ["U"] = {
        "X   X",
        "X   X",
        "X   X",
        "X   X",
        "X   X",
        "X   X",
        " XXX ",
    },
    ["V"] = {
        "X   X",
        "X   X",
        "X   X",
        "X   X",
        "X   X",
        " X X ",
        "  X  ",
    },
    ["W"] = {
        "X   X",
        "X   X",
        "X   X",
        "X   X",
        "X X X",
        "XX XX",
        "X   X",
    },
    ["X"] = {
        "X   X",
        "X   X",
        " X X ",
        "  X  ",
        " X X ",
        "X   X",
        "X   X",
    },
    ["Y"] = {
        "X   X",
        "X   X",
        " X X ",
        "  X  ",
        "  X  ",
        "  X  ",
        "  X  ",
    },
    ["Z"] = {
        "XXXXX",
        "    X",
        "   X ",
        "  X  ",
        " X   ",
        "X    ",
        "XXXXX",
    },
    [" "] = {
        "     ",
        "     ",
        "     ",
        "     ",
        "     ",
        "     ",
        "     ",
    },
}

local teethUnitDefIDs = {}
local function cacheTeethUnitDefIDs()
    for unitDefID, unitDef in pairs(UnitDefs) do
        local nameLower = string.lower(unitDef.translatedHumanName)
        if string.find(nameLower, "teeth") or string.find(nameLower, "fort") then
            teethUnitDefIDs[unitDefID] = true
        end
    end
end

-- Converts a string to a list of coordinates for each character
local function stringToCoords(str, charSpacing)
    charSpacing = charSpacing or 1
    local coords = {}
    str = string.upper(str)
    for i = 1, #str do
        local ch = str:sub(i,i)
        local bitmap = font5x7[ch] or font5x7[" "]
        for row = 1, #bitmap do
            for col = 1, #bitmap[row] do
                if bitmap[row]:sub(col,col) == "X" then
                    table.insert(coords, {
                        x = (i-1)*(5+charSpacing) + (col-1),
                        z = row - 1, -- y=0 is bottom
                        char = ch
                    })
                end
            end
        end
    end
    return coords
end

local function drawTeeth(message, worldPos, selectedUnits)
    -- Implement tooth drawing logic here
    local coords = stringToCoords(message, 1)
    -- give commands to build dragon teeth in the coordinates of the message
    for _, unitID in ipairs(selectedUnits) do
        for unitDefID, _ in pairs(teethUnitDefIDs) do
            for _, pt in ipairs(coords) do
                local wx = tonumber(worldPos[1]) + tonumber(pt.x * 40)
                local wz = tonumber(worldPos[3]) + tonumber(pt.z * 40)
                -- command the unit to build there
                spGiveOrderToUnit(unitID, -unitDefID, {wx, worldPos[2], wz}, {"shift"})
            end
        end
    end
end

local function spell(_, _, params)
    local message = table.concat(params, " ")
    if message == "" then message = "GG" end
    local coords = stringToCoords(message, 1)

    local mouseX, mouseY = spGetMouseState()
    local _, worldPos = spTraceScreenRay(mouseX, mouseY, true)
    if not worldPos then
        return
    end

    local selectedUnits = spGetSelectedUnits()

    -- check if the first unit  is a constructor
    local isConstructor = false
    if selectedUnits[1] then
        local unitDefID = spGetUnitDefID(selectedUnits[1])
        isConstructor = UnitDefs[unitDefID].isBuilder
        if isConstructor then
            drawTeeth(message, worldPos, selectedUnits)
            return
        end
    end

    local numUnits = #selectedUnits
    local numCoords = #coords
    local numToAssign = math.min(numUnits, numCoords)

    for i = 1, numToAssign do
        local unitID = selectedUnits[i]
        local pt = coords[i]
        local wx = tonumber(worldPos[1]) + tonumber(pt.x * 40)
        local wz = tonumber(worldPos[3]) + tonumber(pt.z * 40)
        -- command the unit to move there
        spGiveOrderToUnit(unitID, CMD_MOVE, {wx, 0, wz}, {})
    end
end

function widget:Initialize()
    cacheTeethUnitDefIDs()

    widgetHandler.actionHandler:AddAction(self, "cheer", spell, nil, 't')
end
