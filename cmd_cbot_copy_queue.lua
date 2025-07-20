local widget = widget ---@type Widget
local CMD_GUARD = CMD.GUARD or 25 -- fallback to 25 if CMD.GUARD is not defined

function widget:GetInfo()
  return {
    name      = "Constructors copy queue of Constructors",
    desc      = "Instead of guarding a Constructors, they will just copy the orders.",
    author    = "uBdead",
    date      = "Jul 18 2025",
    license   = "GPL v3 or later",
    layer     = 0,
    enabled   = true  
  }
end

local constructorDefs = {}

function widget:Initialize()
    for udid, ud in pairs(UnitDefs) do
        if ud.isBuilder and not ud.isFactory then
            constructorDefs[udid] = true
        end
    end
end

local ctrlHeldOnPress = false
local altHeldOnPress = false

function widget:MousePress(x, y, button)
    local alt, ctrl, meta, shift = Spring.GetModKeyState()
    ctrlHeldOnPress = ctrl
    altHeldOnPress = alt
    return false -- Don't eat the event
end

function widget:UnitCommand(unitID, unitDefID, teamID, cmdID, cmdParams, cmdOptions, playerID, fromSynced, fromLua)
    -- if fromLua then
    --     Spring.Echo("UnitCommand from Lua, ignoring.")
    --     return true
    -- end

    local ctrlHeld = ctrlHeldOnPress
    local altHeld = altHeldOnPress

    if not ctrlHeld and not altHeld then
        -- If ctrl or alt is not held, do not process this command
        return false
    end

    if not constructorDefs[unitDefID] then
        return
    end

    if cmdID ~= CMD_GUARD then
        return
    end

    -- Get the command queue of the target
    local targetUnitID = cmdParams[1]
    if not targetUnitID or not Spring.ValidUnitID(targetUnitID) then
        return
    end

    local targetDefID = Spring.GetUnitDefID(targetUnitID)
    if not constructorDefs[targetDefID] then
        -- Spring.Echo("Target is not a constructor, guarding instead.")
        return
    end

    local commands = Spring.GetUnitCommands(targetUnitID, -1)
    if not commands or #commands == 0 then
        return
    end

    -- If ctrl is held, shuffle the commands 
    if ctrlHeld then
        -- Shuffle the commands
        for i = #commands, 2, -1 do
            local j = math.random(i)
            commands[i], commands[j] = commands[j], commands[i]
        end
    end

    -- Spring.Echo("Copying command queue from target unit " .. targetUnitID .. " to unit " .. unitID)
    Spring.GiveOrderToUnit(unitID, CMD.STOP, {}, 0) -- clear queue
    for i = 1, #commands do
        local cmd = commands[i]
        Spring.GiveOrderToUnit(unitID, cmd.id, cmd.params, cmd.options)
    end

    -- And finally also add a command to guard the target
    --Spring.GiveOrderToUnit(unitID, CMD_GUARD, {targetUnitID}, {shift = true})

    return true -- Command handled, stop further processing
end
