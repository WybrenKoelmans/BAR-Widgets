---@diagnostic disable: undefined-global, inject-field, undefined-field, undefined-doc-name

local widget = widget --- @type Widget

-- Cache Spring.* functions as locals
local spGetSelectedUnits = Spring.GetSelectedUnits
local spGetUnitDefID = Spring.GetUnitDefID
local spGetUnitPosition = Spring.GetUnitPosition
local spGetCommandQueue = Spring.GetCommandQueue
local spGetUnitsInSphere = Spring.GetUnitsInSphere
local spGiveOrderToUnit = Spring.GiveOrderToUnit
local CMD_STOP = CMD.STOP

function widget:GetInfo()
  return {
    name    = "Smart Miners",
    desc    = "Miners remember where they placed mines, and re-mine when needed.",
    author  = "uBdead",
    date    = "2025.08.31",
    license = "GNU GPL, v2 or later",
    layer   = 0,
    enabled = true,
    depends = { 'gl4' }
  }
end

local mineUnitDefIDs = {}
local mineConstructorUnitDefIDs = {} -- unitDefID -> {mineUnitDefID, ...}
local minerMemory = {}    -- unitID -> { {x, y, z, mineUnitDefID}, ... }
local minerPositions = {} -- unitID -> {x, y, z}

local font

function widget:ViewResize()
  if WG and WG['fonts'] and WG['fonts'].getFont then
    font = WG['fonts'].getFont(nil, 1.2, 0.2, 20)
  else
    font = font or (gl and gl.LoadFont and gl.LoadFont("FreeSansBold", 16, 1.2, 0.2, 20))
  end
end

function widget:Initialize()
  widget:ViewResize()
  for unitDefID, unitDef in pairs(UnitDefs) do
    if unitDef.customParams.mine then
      mineUnitDefIDs[unitDefID] = true
    end
  end

  for unitDefID, unitDef in pairs(UnitDefs) do
    if unitDef.buildOptions then
      local mineList = {}
      for _, buildDefID in ipairs(unitDef.buildOptions) do
        if mineUnitDefIDs[buildDefID] then
          table.insert(mineList, buildDefID)
        end
      end
      if #mineList > 0 then
        mineConstructorUnitDefIDs[unitDefID] = mineList
      end
    end
  end
end

function widget:CommandNotify(cmdID, cmdParams, cmdOptions)
  local selectedUnits = spGetSelectedUnits()
  local selectedMiners = {}
  for _, unitID in ipairs(selectedUnits) do
    local unitDefID = spGetUnitDefID(unitID)
    if mineConstructorUnitDefIDs[unitDefID] then
      selectedMiners[#selectedMiners + 1] = unitID
    end
  end

  if #selectedMiners == 0 then return end -- no miners selected

  if cmdID >= 0 then                      -- not a build command
    for _, minerID in ipairs(selectedMiners) do
      local x, y, z = cmdParams[1], cmdParams[2], cmdParams[3]
      if cmdID == CMD_STOP then
        minerMemory[minerID] = nil -- clear memory on stop
        minerPositions[minerID] = nil
      end

      if cmdID == CMD.REPAIR and #cmdParams == 4 then
        -- add all the existing mines in the repair area to memory, but only if this miner can build that mine type
        local minerUnitDefID = spGetUnitDefID(minerID)
        local canBuildMines = mineConstructorUnitDefIDs[minerUnitDefID] or {}
        local canBuildSet = {}
        for _, mineDefID in ipairs(canBuildMines) do
          canBuildSet[mineDefID] = true
        end
        local units = spGetUnitsInSphere(cmdParams[1], cmdParams[2], cmdParams[3], cmdParams[4]) or {}
        for _, targetID in ipairs(units) do
          local targetUnitDefID = spGetUnitDefID(targetID)
          if mineUnitDefIDs[targetUnitDefID] and canBuildSet[targetUnitDefID] then
            if not minerMemory[minerID] then
              minerMemory[minerID] = {}
            end
            local mx, my, mz = spGetUnitPosition(targetID)
            local fx = mx and math.floor(mx) or 0
            local fy = my and math.floor(my) or 0
            local fz = mz and math.floor(mz) or 0
            table.insert(minerMemory[minerID], { mx, my, mz, targetUnitDefID })
            -- Spring.Echo("Smart Miner: Remembering mine at (" .. fx .. ", " .. fy .. ", " .. fz .. ")")
          end
        end
      end
    end
    return
  end

  -- check if its a mine build command
  if not mineUnitDefIDs[-cmdID] then
    return
  end

  for _, minerID in ipairs(selectedMiners) do
    local x, y, z = cmdParams[1], cmdParams[2], cmdParams[3]
    local mineUnitDefID = -cmdID -- mine build command IDs are negative of unitDefID
    if not minerMemory[minerID] then
      minerMemory[minerID] = {}
    end
    table.insert(minerMemory[minerID], { x, y, z, mineUnitDefID })
  end
end

function widget:UnitDestroyed(unitID, unitDefID, teamID)
  minerMemory[unitID] = nil
end

function widget:GameFrame(frameNum)
  if frameNum % 300 ~= 1 then return end -- every 300 frames 

  -- Step 1: Gather all missing mine orders and which miners remember them and are available
  local mineOrders = {} -- key -> {mx, my, mz, mineUnitDefID, miners={minerID,...}}
  local availableMiners = {} -- minerID -> {x, y, z}

  for minerID, memory in pairs(minerMemory) do
    local x, y, z = spGetUnitPosition(minerID)
    if not x then
      minerMemory[minerID] = nil -- miner no longer exists
    else
      local currentCommandQueue = spGetCommandQueue(minerID, 1) or {}
      if #currentCommandQueue == 0 then
        availableMiners[minerID] = {x, y, z}
      end
      if memory then
        for _, mineInfo in ipairs(memory) do
          local mx, my, mz, mineUnitDefID = mineInfo[1], mineInfo[2], mineInfo[3], mineInfo[4]
          if mx and my and mz and mineUnitDefID then
            local found = false
            local nearbyUnits = spGetUnitsInSphere(mx, my, mz, 10) or {}
            for _, nearbyUnitID in ipairs(nearbyUnits) do
              local nearbyUnitDefID = spGetUnitDefID(nearbyUnitID)
              if nearbyUnitDefID == mineUnitDefID then
                found = true
                break
              end
            end
            if not found then
              local key = string.format("%d_%d_%d_%d", math.floor(mx+0.5), math.floor(my+0.5), math.floor(mz+0.5), mineUnitDefID)
              if not mineOrders[key] then
                mineOrders[key] = {mx=mx, my=my, mz=mz, mineUnitDefID=mineUnitDefID, miners={}}
              end
              table.insert(mineOrders[key].miners, minerID)
            end
          end
        end
      end
    end
  end

  -- Step 2: Distribute orders as evenly as possible among available miners
  local minerOrderCounts = {} -- minerID -> count
  for minerID in pairs(availableMiners) do
    minerOrderCounts[minerID] = 0
  end

  local assignments = {} -- { {minerID, mx, my, mz, mineUnitDefID} }
  for _, order in pairs(mineOrders) do
    -- Only consider available miners for this order
    local eligible = {}
    for _, minerID in ipairs(order.miners) do
      if availableMiners[minerID] then
        table.insert(eligible, minerID)
      end
    end
    if #eligible > 0 then
      -- Find the eligible miner with the least assignments so far
      table.sort(eligible, function(a, b) return minerOrderCounts[a] < minerOrderCounts[b] end)
      local chosenMiner = eligible[1]
      table.insert(assignments, {minerID=chosenMiner, mx=order.mx, my=order.my, mz=order.mz, mineUnitDefID=order.mineUnitDefID})
      minerOrderCounts[chosenMiner] = minerOrderCounts[chosenMiner] + 1
    end
  end

  -- Step 3: Issue the build orders
  for _, assign in ipairs(assignments) do
    local minerID = assign.minerID
    local mx, my, mz = assign.mx, assign.my, assign.mz
    local mineUnitDefID = assign.mineUnitDefID
    local pos = availableMiners[minerID]
    if pos then
      minerPositions[minerID] = { pos[1], pos[2], pos[3] }
      -- Spring.Echo("Smart Miner: Rebuilding mine at (" .. math.floor(mx) .. ", " .. math.floor(my) .. ", " .. math.floor(mz) .. ") (mineUnitDefID: " .. mineUnitDefID .. ") by miner " .. minerID)
      spGiveOrderToUnit(minerID, -mineUnitDefID, { mx, my, mz }, { "shift" })
    end
  end
end

function widget:UnitIdle(unitID, unitDefID, teamID)
  if not minerPositions[unitID] then
    return
  end

  -- return to original position
  local pos = minerPositions[unitID]
  if pos[1] then
    spGiveOrderToUnit(unitID, CMD.MOVE, { pos[1], pos[2], pos[3] }, {})
    -- Spring.Echo("Smart Miner: Returning to original position at (" .. math.floor(pos[1]) .. ", " .. math.floor(pos[2]) .. ", " .. math.floor(pos[3]) .. ")")
    minerPositions[unitID] = nil
  else
    local x,y,z = spGetUnitPosition(unitID)
    minerPositions[unitID] = { x, y, z }
  end
end


local glColor = gl.Color
local glDepthTest = gl.DepthTest
local glDrawFuncAtUnit = gl.DrawFuncAtUnit
local glBillboard = gl.Billboard
local glTranslate = gl.Translate


local function drawMineCountLabel(mineCount, memory)
  glBillboard()
  glTranslate(0, 20, 0)
  if font then
    font:Begin()
    font:Print("Mines: " .. tostring(mineCount), 0, 0, 9, "oc")
    -- Add debug data: show up to 3 mine memory entries
    -- if memory and #memory > 0 then
    --   for i = 1, math.min(3, #memory) do
    --     local mine = memory[i]
    --     if mine then
    --       local mx, my, mz, mineUnitDefID = mine[1], mine[2], mine[3], mine[4]
    --       local debugStr = string.format("[%d] (%.0f,%.0f,%.0f) id:%s", i, mx or 0, my or 0, mz or 0, tostring(mineUnitDefID))
    --       font:Print(debugStr, 0, -10 * i, 7, "oc")
    --     end
    --   end
    --   if #memory > 3 then
    --     font:Print("...", 0, -40, 7, "oc")
    --   end
    -- end
    font:End()
  end
end

function widget:DrawWorld()
  if not font or Spring.IsGUIHidden() then return end
  glDepthTest(true)
  glColor(1, 1, 0, 0.8)
  for minerID, memory in pairs(minerMemory) do
    if memory and #memory > 0 then
      glDrawFuncAtUnit(minerID, false, drawMineCountLabel, #memory, memory)
    end
  end
  glColor(1, 1, 1, 1)
  glDepthTest(false)
end

