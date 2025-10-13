-- luacheck: ignore widget RmlUi CMD GameCMD
if not RmlUi then
    return false
end

local widget = widget ---@type Widget

-- Cache Spring.* calls as local sp* variables
local spGetSelectedUnits = Spring.GetSelectedUnits
local spGetUnitDefID = Spring.GetUnitDefID
local spGetMouseState = Spring.GetMouseState
local spTraceScreenRay = Spring.TraceScreenRay
local spGetModKeyState = Spring.GetModKeyState
local spGetActiveCommand = Spring.GetActiveCommand
local spGetViewGeometry = Spring.GetViewGeometry

local CMD_RECLAIM = CMD.RECLAIM
local CMD_RESURRECT = CMD.RESURRECT
local CMD_REPAIR = CMD.REPAIR
local CMD_ATTACK = CMD.ATTACK
local CMD_AREA_ATTACK = CMD.AREA_ATTACK
local CMD_PATROL = CMD.PATROL
local CMD_FIGHT = CMD.FIGHT

function widget:GetInfo()
    return {
        name = "Control Hints",
        desc = "Show little hints about controls when in the proper context",
        author = "uBdead",
        date = "2025-10-10",
        license = "GNU GPL, v2 or later",
        layer = -1000000,
        enabled = true,
    }
end

local moveableUnitDefIDs = {}
local constructorUnitDefIDs = {}
local paralyserUnitDefIDs = {}

-- Constants
local WIDGET_NAME = "gui_control_hints"
local MODEL_NAME = "gui_control_hints_model"
local RML_PATH = "LuaUI/Widgets/gui_control_hints/gui_control_hints.rml"

-- Widget state
local document
local container
local dm_handle

local hints = {}
local needReload = false

-- Initial data model
local init_model = {
    debug = "",
    cmdID = 0,
    alt = false,
    ctrl = false,
    meta = false,
    shift = false,
    hints = hints,
    moveable = -1,
    constructor = -1,
    paralyser = -1,
    target = -1,
    show = false,
}

local function toTernary(nilable)
    if nilable == nil then
        return -1
    elseif nilable == true then
        return 1
    else
        return 0
    end
end

local function addHint(cmdID, ctrl, alt, meta, shift, label, value, moveable, constructor, paralyser, target)
    table.insert(hints, {
        cmdID = cmdID,
        alt = alt,
        ctrl = ctrl,
        meta = meta,
        shift = shift,
        label = label,
        value = value,
        active = false,
        moveable = toTernary(moveable),
        constructor = toTernary(constructor),
        paralyser = toTernary(paralyser),
        target = toTernary(target),
    })

    if needReload then
        dm_handle.hints = hints
    end
end

local function addHints()
    --[[ General ]]
    addHint(0, false, false, true, false, "SPACE+X", "Explosion radius", false)
    --[[ CONSTRUCTION ]]
    addHint(-1, false, false, false, true, "SHIFT+DRAG", "Line")
    addHint(-1, true, false, false, true, "CTRL+SHIFT+DRAG", "Line (straight)", nil, nil, nil, false)
    addHint(-1, false, true, false, true, "SHIFT+ALT+DRAG", "Grid")
    addHint(-1, true, false, false, true, "CTRL+SHIFT+TARGET", "Surround", nil, nil, nil, true)
    addHint(-1, false, false, true, true, "SHIFT+SPACE+DRAG", "Split")
    addHint(-1, false, true, false, true, "SHIFT+ALT+Z/X", "Spacing")
    addHint(-1, false, false, true, false, "SPACE", "Explosion radius")
    --[[ RECLAIM ]]
    addHint(CMD_RECLAIM, false, false, false, false, "DRAG", "Area")
    addHint(CMD_RECLAIM, true, false, false, false, "CTRL+DRAG", "Area (metal first)", nil, nil, nil, false)
    addHint(CMD_RECLAIM, true, false, false, false, "CTRL+TARGET+DRAG", "Targets", nil, nil, nil, true)
    -- addHint(CMD_RECLAIM, true, false, true, false, "CTRL+SPACE+ENEMY+DRAG", "Enemies", nil, nil, nil, true)
    addHint(CMD_RECLAIM, false, true, false, false, "ALT+DRAG", "Area (forever)", nil, nil, nil, false)
    addHint(CMD_RECLAIM, false, true, false, false, "ALT+TARGET+DRAG", "Targets of type", nil, nil, nil, true)
    --[[ RESURRECT ]]
    addHint(CMD_RESURRECT, false, false, false, false, "DRAG", "Area")
    addHint(CMD_RESURRECT, false, true, false, false, "ALT+DRAG", "Area (forever)")
    -- addHint(CMD_RESURRECT, false, false, false, false, "SPACE+DRAG", "Area (keep, fresh only)") --????
    --[[ REPAIR ]]
    addHint(CMD_REPAIR, false, false, false, false, "DRAG", "Area")
    addHint(CMD_REPAIR, false, true, false, false, "ALT+DRAG", "Area (forever)")
    -- addHint(CMD_REPAIR, false, false, true, false, "SPACE+DRAG", "Area (no assist)") --????
    --[[ ATTACK ]]
    addHint(CMD_ATTACK, false, false, false, false, "DRAG", "Area")
    addHint(CMD_ATTACK, false, true, false, false, "ALT+DRAG", "Keep target", nil, nil, true) -- paralyser
    --[[ ATTACK (static)]]
    -- addHint(CMD_ATTACK, false, false, false, false, "SPACE", "Keep order", false, false)
    --[[ ATTACK AREA ]]
    addHint(CMD_AREA_ATTACK, false, false, false, false, "DRAG", "Area")
    addHint(GameCMD.AREA_ATTACK_GROUND, false, false, false, false, "DRAG", "Area")
    --[[ AREA MEX ]]
    addHint(GameCMD.AREA_MEX, false, false, false, false, "DRAG", "Area")
    --[[ SET TARGET ]]
    addHint(GameCMD.UNIT_SET_TARGET, false, false, false, false, "DRAG", "Area")
    addHint(GameCMD.UNIT_SET_TARGET, false, false, false, false, "CTRL+S", "Cancel existing")
    addHint(GameCMD.UNIT_SET_TARGET, false, true, false, false, "ALT+TARGET", "Priority target type", nil, nil, nil, true)
    addHint(GameCMD.UNIT_SET_TARGET, false, true, false, false, "ALT+TARGET+DRAG", "Set target type", nil, nil, nil, true)
    --[[ MOVE ]]
    addHint(0, false, true, false, false, "ALT", "Form Front", true, false)
    addHint(0, true, false, false, false, "CTRL", "Formation", true, false)
    --[[ PATROL ]]
    addHint(CMD_PATROL, true, false, false, false, "CTRL", "Formation")
    addHint(CMD_PATROL, false, false, false, false, "NORMAL", "Reclaim", true, true)
    addHint(CMD_PATROL, false, true, false, false, "ALT", "Resurrect (first)", true, true)
    --[[ FIGHT (combat)]]
    addHint(CMD_FIGHT, true, false, false, false, "CTRL", "Formation", false, false)
    addHint(CMD_FIGHT, true, false, false, false, "CTRL+DRAG", "Formation + Front", false, false)
    --[[ FIGHT (builders)]]
    addHint(CMD_FIGHT, false, false, false, false, "NORMAL", "Reclaim", true, true)
    addHint(CMD_FIGHT, false, true, false, false, "ALT", "Resurrect (first)", true, true)

    needReload = true
end

addHints()

local function cacheUnitDefs()
    for uDefID, uDef in pairs(UnitDefs) do
        if uDef.canMove then
            moveableUnitDefIDs[uDefID] = true
        end
        if uDef.isBuilder then
            constructorUnitDefIDs[uDefID] = true
        end
        -- check the weapon defs for paralyser damage
        if #uDef.weapons > 0 then
            for i=1,#uDef.weapons do
                local weaponDef = WeaponDefs[uDef.weapons[i].weaponDef]
                if weaponDef and weaponDef.paralyzer then
                    paralyserUnitDefIDs[uDefID] = true
                    break
                end
            end
        end
    end
end

function widget:Initialize()
    RmlUi.LoadFontFace("fonts/monospaced/SourceCodePro-Medium.otf")

    cacheUnitDefs()

    if widget:GetInfo().enabled == false then
        return false
    end

    -- Get the shared RML context
    widget.rmlContext = RmlUi.GetContext("shared")
    if not widget.rmlContext then
        return false
    end

    -- Create and bind the data model
    dm_handle = widget.rmlContext:OpenDataModel(MODEL_NAME, init_model)
    if not dm_handle then
        return false
    end

    -- Load the RML document
    document = widget.rmlContext:LoadDocument(RML_PATH, widget)
    if not document then
        widget:Shutdown()
        return false
    end

    -- Apply styles and show the document
    document:ReloadStyleSheet()
    document:Show()

    container = document:GetElementById("gui_control_hints_model-widget")

    -- now register an API so other widgets can add hints too
    WG['gui_control_hints'] = {}
    WG['gui_control_hints'].addHint = addHint

    return true
end

function widget:GameFrame(frame)
    -- a selected unit
    local selectedUnits = spGetSelectedUnits()
    if #selectedUnits == 0 then
        dm_handle.show = false
        return
    end
    local selectedUnitID = selectedUnits[1]
    local selectedUnitDefID = spGetUnitDefID(selectedUnitID)
    if not selectedUnitDefID then
        dm_handle.show = false
        return
    end

    if frame % 5 ~= 4 then
        return
    end
    local mx, my = spGetMouseState()
    local desc = spTraceScreenRay(mx, my)
    dm_handle.target = toTernary(desc ~= "ground")

    dm_handle.moveable = toTernary(moveableUnitDefIDs[selectedUnitDefID] ~= nil)
    dm_handle.constructor = toTernary(constructorUnitDefIDs[selectedUnitDefID] ~= nil)
    dm_handle.paralyser = toTernary(paralyserUnitDefIDs[selectedUnitDefID] ~= nil)

    dm_handle.show = true
    local alt, ctrl, meta, shift = spGetModKeyState()
    dm_handle.alt = alt
    dm_handle.ctrl = ctrl
    dm_handle.meta = meta
    dm_handle.shift = shift
    local _, cmdID = spGetActiveCommand()
    if cmdID == nil then cmdID = 0 end
    dm_handle.cmdID = cmdID

    -- dm_handle.debug = string.format("cmdID: %d, alt: %s, ctrl: %s, meta: %s, shift: %s, moveable: %s, constructor: %s, paralyser: %s, target: %s",
    --     cmdID, tostring(alt), tostring(ctrl),
    --     tostring(meta), tostring(shift), tostring(dm_handle.moveable), tostring(dm_handle.constructor), tostring(dm_handle.paralyser), tostring(dm_handle.target))
end

function widget:Shutdown()
    -- Clean up data model
    if widget.rmlContext and dm_handle then
        widget.rmlContext:RemoveDataModel(MODEL_NAME)
        dm_handle = nil
    end

    -- Close document
    if document then
        document:Close()
        document = nil
    end

    widget.rmlContext = nil

    -- Remove API
    WG['gui_control_hints'] = nil
end

-- Widget functions callable from RML
function widget:Reload()
    widget:Shutdown()
    widget:Initialize()
end

function widget:DrawScreen()
    if container then
        -- get the mouse position
        local mx, my = spGetMouseState()
        local vsx, vsy = spGetViewGeometry()
        local margin = 20
        container:SetAttribute("style", string.format("top: %dpx; left: %dpx;", (vsy - my + margin), mx + margin))
    end
end
