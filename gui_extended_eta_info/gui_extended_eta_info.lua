local widget = widget ---@type Widget

function widget:GetInfo()
	return {
		name = "Extended ETA Info",
		desc = "Shows remaining metal cost below the build ETA",
		author = "uBdead",
		date = "2026-04-18",
		license = "GNU GPL, v2 or later",
		layer = -8,
		enabled = true
	}
end

local spGetUnitViewPosition = Spring.GetUnitViewPosition
local spGetGameSeconds = Spring.GetGameSeconds
local spGetUnitIsBeingBuilt = Spring.GetUnitIsBeingBuilt
local spGetUnitAllyTeam = Spring.GetUnitAllyTeam
local spGetSpectatingState = Spring.GetSpectatingState
local spec, fullview = spGetSpectatingState()
local myAllyTeam = Spring.GetMyAllyTeamID()

local glColor = gl.Color
local glDepthTest = gl.DepthTest
local glDrawFuncAtUnit = gl.DrawFuncAtUnit
local glBillboard = gl.Billboard
local glTranslate = gl.Translate

local mathCeil = math.ceil

local font

local unitInfo = {} -- unitID -> { metalLeft, yoffset, defID }
local maxDrawDist = 750000
local lastGameUpdate = spGetGameSeconds()

local unitHeight = {}
local unitMetalCost = {}
for udid, unitDef in pairs(UnitDefs) do
	unitHeight[udid] = unitDef.height
	unitMetalCost[udid] = unitDef.metalCost
end

function widget:ViewResize()
	font = WG['fonts'].getFont(nil, 1.2, 0.2, 20)
end

local function addUnit(unitID, unitDefID)
	if unitDefID == nil then return end
	local isBuilding, buildProgress = spGetUnitIsBeingBuilt(unitID)
	if not isBuilding then return end
	unitInfo[unitID] = {
		metalLeft = mathCeil((1 - buildProgress) * unitMetalCost[unitDefID]),
		yoffset = unitHeight[unitDefID] + 14,
		defID = unitDefID,
	}
end

local function init()
	unitInfo = {}
	local units = Spring.GetAllUnits()
	for i = 1, #units do
		local unitID = units[i]
		if fullview or spGetUnitAllyTeam(unitID) == myAllyTeam then
			addUnit(unitID, Spring.GetUnitDefID(unitID))
		end
	end
end

function widget:Initialize()
	widget:ViewResize()
	init()
end

function widget:Update(dt)
	local gs = spGetGameSeconds()
	if gs == lastGameUpdate then return end
	lastGameUpdate = gs

	local toRemove = {}
	local removeCount = 0
	for unitID, info in pairs(unitInfo) do
		local isBuilding, buildProgress = spGetUnitIsBeingBuilt(unitID)
		if not isBuilding then
			removeCount = removeCount + 1
			toRemove[removeCount] = unitID
		else
			info.metalLeft = mathCeil((1 - buildProgress) * unitMetalCost[info.defID])
		end
	end
	for i = 1, removeCount do
		unitInfo[toRemove[i]] = nil
	end
end

function widget:PlayerChanged()
	if myAllyTeam ~= Spring.GetMyAllyTeamID() or fullview ~= select(2, spGetSpectatingState()) then
		myAllyTeam = Spring.GetMyAllyTeamID()
		spec, fullview = spGetSpectatingState()
		init()
	end
end

function widget:UnitCreated(unitID, unitDefID)
	if fullview or spGetUnitAllyTeam(unitID) == myAllyTeam then
		addUnit(unitID, unitDefID)
	end
end

function widget:UnitDestroyed(unitID)
	unitInfo[unitID] = nil
end

function widget:UnitTaken(unitID)
	unitInfo[unitID] = nil
end

function widget:UnitFinished(unitID)
	unitInfo[unitID] = nil
end

local function drawMetalText(metalLeft, yoffset)
	glTranslate(0, yoffset, 10)
	glBillboard()
	glTranslate(0, -3, 0)
	font:Begin()
	font:Print("\255\192\192\192M: \255\180\180\255" .. metalLeft, 0, -10, 6, "co")
	font:End()
end

function widget:DrawWorld()
	if Spring.IsGUIHidden() then return end

	local glStateReady = false
	local cx, cy, cz = Spring.GetCameraPosition()

	for unitID, info in pairs(unitInfo) do
		local ux, uy, uz = spGetUnitViewPosition(unitID)
		if ux then
			local dx, dy, dz = ux - cx, uy - cy, uz - cz
			local dist = dx * dx + dy * dy + dz * dz
			if dist < maxDrawDist then
				if not glStateReady then
					glDepthTest(true)
					glColor(1, 1, 1, 0.1)
					glStateReady = true
				end
				glDrawFuncAtUnit(unitID, false, drawMetalText, info.metalLeft, info.yoffset)
			end
		end
	end

	if glStateReady then
		glColor(1, 1, 1, 1)
		glDepthTest(false)
	end
end
