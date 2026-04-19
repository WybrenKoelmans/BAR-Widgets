local widget = widget ---@type Widget

function widget:GetInfo()
	return {
		name = "Extended ETA Info",
		desc = "Shows remaining resource cost below the build ETA",
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
local spGetModKeyState = Spring.GetModKeyState
local spGetTeamResources = Spring.GetTeamResources
local spGetUnitTeam = Spring.GetUnitTeam

local glColor = gl.Color
local glDepthTest = gl.DepthTest
local glDrawFuncAtUnit = gl.DrawFuncAtUnit
local glBillboard = gl.Billboard
local glTranslate = gl.Translate

local mathCeil = math.ceil
local mathFloor = math.floor

local font

local unitInfo = {} -- unitID -> { metalLeft, energyLeft, yoffset, defID, progress, team }
local maxDrawDist = 750000
local lastGameUpdate = spGetGameSeconds()

local unitHeight = {}
local unitMetalCost = {}
local unitEnergyCost = {}
for udid, unitDef in pairs(UnitDefs) do
	unitHeight[udid] = unitDef.height
	unitMetalCost[udid] = unitDef.metalCost or 0
	unitEnergyCost[udid] = unitDef.energyCost or 0
end

function widget:ViewResize()
	font = WG['fonts'].getFont(nil, 1.2, 0.2, 20)
end

local function addUnit(unitID, unitDefID)
	if unitDefID == nil then return end
	local isBuilding, buildProgress = spGetUnitIsBeingBuilt(unitID)
	if not isBuilding then return end
	unitInfo[unitID] = {
		metalLeft = mathCeil((1 - buildProgress) * (unitMetalCost[unitDefID] or 0)),
		energyLeft = mathCeil((1 - buildProgress) * (unitEnergyCost[unitDefID] or 0)),
		yoffset = unitHeight[unitDefID] - 5,
		defID = unitDefID,
		progress = buildProgress,
		team = spGetUnitTeam(unitID),
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
	-- throttle updates to at most once per second
	if gs - lastGameUpdate < 1 then return end
	lastGameUpdate = gs

	local toRemove = {}
	local removeCount = 0
	for unitID, info in pairs(unitInfo) do
		local isBuilding, buildProgress = spGetUnitIsBeingBuilt(unitID)
		if not isBuilding then
			removeCount = removeCount + 1
			toRemove[removeCount] = unitID
		else
			info.metalLeft = mathCeil((1 - buildProgress) * (unitMetalCost[info.defID] or 0))
			info.energyLeft = mathCeil((1 - buildProgress) * (unitEnergyCost[info.defID] or 0))
			info.progress = buildProgress
			info.team = info.team or spGetUnitTeam(unitID)
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

local function trimTrailingZeros(s)
	s = s:gsub("%.?0+$", "")
	return s
end

local function formatCount(n)
	if n == nil then return "0" end
	local sign = n < 0 and "-" or ""
	local absn = math.abs(n)
	if absn >= 1e12 then
		return sign .. trimTrailingZeros(string.format("%.1f", absn / 1e12)) .. "T"
	elseif absn >= 1e9 then
		return sign .. trimTrailingZeros(string.format("%.1f", absn / 1e9)) .. "B"
	elseif absn >= 1e6 then
		return sign .. trimTrailingZeros(string.format("%.1f", absn / 1e6)) .. "M"
	elseif absn >= 1e3 then
		return sign .. trimTrailingZeros(string.format("%.1f", absn / 1e3)) .. "K"
	else
		-- Round small numbers to nearest integer for cleaner display
		return sign .. tostring(mathFloor(absn + 0.5))
	end
end

-- energy color: prefer project YellowStr, fallback to top-bar yellow
local energyColorStr = YellowStr or "\255\255\230\80"

local function drawCostText(metalLeft, energyLeft, yoffset)
	glTranslate(0, yoffset, 10)
	glBillboard()
	font:Begin()
	local mText = formatCount(metalLeft)
	local eText = formatCount(energyLeft)
	local fontSize = 6
	-- anchor first (only) line at the top (y=0)
	font:Print("\255\192\192\192M: \255\180\180\255" .. mText .. " \255\192\192\192E: " .. energyColorStr .. eText, 0, 0,
		fontSize, "co")
	font:End()
end

function widget:DrawWorld()
	if Spring.IsGUIHidden() then return end

	local glStateReady = false
	local cx, cy, cz = Spring.GetCameraPosition()
	local _, _, _, shift = spGetModKeyState()

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
				glDrawFuncAtUnit(unitID, false, drawCostText, info.metalLeft, info.energyLeft, info.yoffset)
			end
		end
	end

	if glStateReady then
		glColor(1, 1, 1, 1)
		glDepthTest(false)
	end
end
