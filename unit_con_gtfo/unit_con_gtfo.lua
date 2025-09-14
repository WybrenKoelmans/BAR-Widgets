local widget = widget ---@type Widget

local ALSO_DONT_SEND_REZBOTS_TO_FRONT = true

function widget:GetInfo()
    return {
        name = "Constructors GTFO",
        desc = "Makes constructors leave the factory faster by giving them a move order immediately after they finish.",
        author = "uBdead",
        date = "2025-09-14",
        license = "GNU GPL, v2 or later",
        layer = 50,
        enabled = true
    }
end

--------------------------------------------------------------------------------
-- Local constants and references
--------------------------------------------------------------------------------
local spGetMyTeamID = Spring.GetMyTeamID
local spGetUnitCmdDescs = Spring.GetUnitCmdDescs
local spGetUnitBuildFacing = Spring.GetUnitBuildFacing
local spGetUnitPosition = Spring.GetUnitPosition
local spGiveOrderToUnit = Spring.GiveOrderToUnit

local CMD_FACTORY_GUARD = GameCMD.FACTORY_GUARD
local FACTORY_EXIT_OFFSET = 75

local alternate = {} -- factoryID -> bool

--------------------------------------------------------------------------------
-- Build isFactory and isAssistBuilder tables (copied logic from unit_factory_guard)
--------------------------------------------------------------------------------
local isFactory = {}
local isAssistBuilder = {}
for unitDefID, unitDef in pairs(UnitDefs) do
    if unitDef.isFactory then
        local buildOptions = unitDef.buildOptions
        for i = 1, #buildOptions do
            local buildOptDefID = buildOptions[i]
            local buildOpt = UnitDefs[buildOptDefID]
            if (buildOpt and buildOpt.isBuilder and buildOpt.canAssist) then
                isFactory[unitDefID] = true
                break
            end
        end
    end
    if unitDef.isBuilder and unitDef.canAssist then
        isAssistBuilder[unitDefID] = true
    end

    if ALSO_DONT_SEND_REZBOTS_TO_FRONT and unitDef.canRepair then
        isAssistBuilder[unitDefID] = true
    end
end

--------------------------------------------------------------------------------
-- Widget Functions
--------------------------------------------------------------------------------
function widget:UnitFromFactory(unitID, unitDefID, unitTeam, factID, factDefID, userOrders)
    -- Only apply to assist builders from eligible factories, and only for player's team, and if no user orders
    if userOrders then return end
    if unitTeam ~= spGetMyTeamID() then return end
    if not isFactory[factDefID] then return end
    if not isAssistBuilder[unitDefID] then return end

    -- Check if factory guard is enabled (using cmdDescIndex)
    local spFindUnitCmdDesc = Spring.FindUnitCmdDesc
    local cmdDescIndex = spFindUnitCmdDesc(factID, CMD_FACTORY_GUARD)
    local guardEnabled = cmdDescIndex and spGetUnitCmdDescs(factID)[cmdDescIndex].params[1] == "1"
    if not guardEnabled then return end

    -- Alternate direction per factory
    alternate[factID] = not alternate[factID]
    local direction = alternate[factID] and 1 or -1

    -- Get the facing of the factory
    local factoryFacing = spGetUnitBuildFacing(factID) or 0
    local xOffset, zOffset = 0, 0
    -- Define left/right relative to factory facing
    -- facing: 0 = south, 1 = east, 2 = north, 3 = west
    -- direction: 1 = right, -1 = left (from factory's perspective)
    if factoryFacing == 0 then -- south
        xOffset = FACTORY_EXIT_OFFSET * direction
    elseif factoryFacing == 1 then -- east
        zOffset = -FACTORY_EXIT_OFFSET * direction
    elseif factoryFacing == 2 then -- north
        xOffset = -FACTORY_EXIT_OFFSET * direction
    elseif factoryFacing == 3 then -- west
        zOffset = FACTORY_EXIT_OFFSET * direction
    end

    local x, y, z = spGetUnitPosition(unitID)
    local targetX, targetZ = x + xOffset, z + zOffset
    spGiveOrderToUnit(unitID, CMD.MOVE, { targetX, y, targetZ }, {})
end
