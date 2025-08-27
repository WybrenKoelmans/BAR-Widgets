---@diagnostic disable: undefined-global, inject-field, need-check-nil, lowercase-global
local widget = widget

function widget:GetInfo()
	return {
		name = "Sensor Ranges Radar Preview (All radars)",
		desc = "Extend Raytraced Radar Range Coverage on all Radars (GL4)",
		author = "uBdead, Beherith",
		date = "2025.08.13",
		license = "Lua: GPLv2, GLSL: (c) Beherith (mysterme@gmail.com) --> IM NOT A LAWYER",
		layer = 0,
		enabled = true
	}
end

------- GL4 NOTES -----
-- This is an addon to gui_sensor_ranges_radar_preview.lua.
-- It draws the same GL4 raytraced radar coverage, but for ALL current team radar towers.

-- Keep this in sync with the original preview shader settings
local SHADERRESOLUTION = 16 -- THIS SHOULD MATCH RADARMIPLEVEL!

local smallradarrange = 2100 -- updated from UnitDefs ('armrad')
local largeradarrange = 3500 -- updated from UnitDefs ('armarad')

-- Cache of radar unitDefIDs and metadata
local radarDefIDs = {}         -- [unitDefID] = "small"|"large"
local radaremitheight = {}     -- [unitDefID] = unitDef.radarEmitHeight + radarYOffset
local radarYOffset = 50        -- amount added to vertical height of overlay to more closely reflect engine radarLOS

-- AllyTeam radar unit caches
local myAllyTeamID = nil
local allowedTeams = {}        -- [teamID] = true for all teams in my allyteam
local smallRadarUnits = {}     -- array of unitIDs
local largeRadarUnits = {}     -- array of unitIDs
local unitIdToBucket = {}      -- [unitID] = "small"|"large" for quick removal
local selectedRadarUnitID = false

-- GL4 handles
local LuaShader = gl.LuaShader
local InstanceVBOTable = gl.InstanceVBOTable
local radarTruthShader = nil
local smallradVAO = nil
local largeradVAO = nil

-- Shader sources from BAR
local vsSrcPath = "LuaUI/Shaders/sensor_ranges_radar_preview.vert.glsl"
local fsSrcPath = "LuaUI/Shaders/sensor_ranges_radar_preview.frag.glsl"

local function goodbye(reason)
	Spring.Echo("Sensor Ranges Radar Preview (All) exiting:", reason)
	widgetHandler:RemoveWidget()
end

local function buildRadarDefCaches()
	-- Derive ranges and cache all radar tower unitDefIDs
	for unitDefID, unitDef in pairs(UnitDefs) do
		if unitDef.name == 'armarad' then
			largeradarrange = unitDef.radarDistance
		end
		if unitDef.name == 'armrad' then
			smallradarrange = unitDef.radarDistance
		end
	end

	for unitDefID, unitDef in pairs(UnitDefs) do
		if unitDef.radarDistance and unitDef.radarDistance > 2000 then
			radaremitheight[unitDefID] = (unitDef.radarEmitHeight or 0) + radarYOffset
			if unitDef.radarDistance == smallradarrange then
				radarDefIDs[unitDefID] = "small"
			elseif unitDef.radarDistance == largeradarrange then
				radarDefIDs[unitDefID] = "large"
			end
		end
	end
end

local function compileShaderDarkerGreen()
	-- Load and slightly modify the vertex shader to use a darker green tone.
	local vsSrc = VFS.LoadFile(vsSrcPath)
	local fsSrc = VFS.LoadFile(fsSrcPath)
	if not vsSrc or not fsSrc then
		return goodbye("Failed to load shader sources")
	end

	-- Ensure engine UBO defines are injected
	local engineUniformBufferDefs = LuaShader.GetEngineUniformBufferDefs and LuaShader.GetEngineUniformBufferDefs() or ""
	vsSrc = vsSrc:gsub("//__ENGINEUNIFORMBUFFERDEFS__", engineUniformBufferDefs)
	fsSrc = fsSrc:gsub("//__ENGINEUNIFORMBUFFERDEFS__", engineUniformBufferDefs)

	-- Darker green tweak: the original shader sets blendedcolor.g = 1.0;
	-- Replace that constant with ~0.75 for a darker green while keeping behavior otherwise identical.
	local replaced
	vsSrc, replaced = vsSrc:gsub("blendedcolor%.g%s*=%s*1%.0%s*;", "blendedcolor.g = 0.75;")
	if replaced == 0 then
		-- Fallback: try a more permissive replacement to stay resilient to minor formatting changes
		vsSrc = vsSrc:gsub("blendedcolor%.[gG]%s*=%s*1%s*;", "blendedcolor.g = 0.75;")
	end

	radarTruthShader = LuaShader(
		{
			vertex = vsSrc,
			fragment = fsSrc,
			uniformInt = { heightmapTex = 0 },
			uniformFloat = {
				radarcenter_range = { 2000, 100, 2000, 2000 },
				resolution = { 128 },
			},
		},
		"radarTruthShader GL4 (All Radars, darker green)"
	)
	if not radarTruthShader:Initialize() then
		return goodbye("Failed to compile radarTruthShader GL4 (All)")
	end
end

local function initGL4()
	compileShaderDarkerGreen()

	local smol = InstanceVBOTable.makePlaneVBO(1, 1, smallradarrange / SHADERRESOLUTION)
	local smoli = InstanceVBOTable.makePlaneIndexVBO(smallradarrange / SHADERRESOLUTION, smallradarrange / SHADERRESOLUTION, true)
	smallradVAO = gl.GetVAO()
	smallradVAO:AttachVertexBuffer(smol)
	smallradVAO:AttachIndexBuffer(smoli)

	local larg = InstanceVBOTable.makePlaneVBO(1, 1, largeradarrange / SHADERRESOLUTION)
	local largi = InstanceVBOTable.makePlaneIndexVBO(largeradarrange / SHADERRESOLUTION, largeradarrange / SHADERRESOLUTION, true)
	largeradVAO = gl.GetVAO()
	largeradVAO:AttachVertexBuffer(larg)
	largeradVAO:AttachIndexBuffer(largi)
end

local function clearTeamCaches()
	smallRadarUnits = {}
	largeRadarUnits = {}
	unitIdToBucket = {}
end

local function addIfMyAllyRadar(unitID, unitDefID, teamID)
	if not allowedTeams[teamID] then return end
	if unitIdToBucket[unitID] then return end -- already tracked
	local bucket = radarDefIDs[unitDefID]
	if not bucket then return end
	-- only track finished buildings
	local _, _, _, _, build = Spring.GetUnitHealth(unitID)
	if build and build < 1 then return end
	if bucket == "small" then
		smallRadarUnits[#smallRadarUnits + 1] = unitID
		unitIdToBucket[unitID] = "small"
	elseif bucket == "large" then
		largeRadarUnits[#largeRadarUnits + 1] = unitID
		unitIdToBucket[unitID] = "large"
	end
end

local function rebuildAllowedTeams()
	allowedTeams = {}
	myAllyTeamID = Spring.GetMyAllyTeamID()
	local teamList = Spring.GetTeamList(myAllyTeamID) or {}
	for i = 1, #teamList do
		allowedTeams[teamList[i]] = true
	end
end

local function rebuildMyAllyRadarUnits()
	clearTeamCaches()
	if not myAllyTeamID then return end
	local teamList = Spring.GetTeamList(myAllyTeamID) or {}
	for t = 1, #teamList do
		local teamID = teamList[t]
		local units = Spring.GetTeamUnits(teamID) or {}
		for i = 1, #units do
			local uID = units[i]
			local uDefID = Spring.GetUnitDefID(uID)
			if uDefID then
				-- ensure finished
				local _, _, _, _, build = Spring.GetUnitHealth(uID)
				if build and build >= 1 then
					addIfMyAllyRadar(uID, uDefID, teamID)
				end
			end
		end
	end
end

function widget:Initialize()
	if not gl.CreateShader then
		return widgetHandler:RemoveWidget()
	end

	buildRadarDefCaches()

	if (smallradarrange > 2200) then
		Spring.Echo("Sensor Ranges Radar Preview (All) does not support increased radar range modoptions; removing.")
		return widgetHandler:RemoveWidget()
	end

	initGL4()

	rebuildAllowedTeams()
	rebuildMyAllyRadarUnits()
end

function widget:SelectionChanged(sel)
	selectedRadarUnitID = false
	if sel and #sel == 1 then
		local uID = sel[1]
		local uDefID = Spring.GetUnitDefID(uID)
		if uDefID and radarDefIDs[uDefID] then
			selectedRadarUnitID = uID
		end
	end
end

local function removeUnitFromBucket(unitID)
	local bucket = unitIdToBucket[unitID]
	if not bucket then return end
	unitIdToBucket[unitID] = nil
	if bucket == "small" then
		for i = #smallRadarUnits, 1, -1 do
			if smallRadarUnits[i] == unitID then
				table.remove(smallRadarUnits, i)
				break
			end
		end
	else
		for i = #largeRadarUnits, 1, -1 do
			if largeRadarUnits[i] == unitID then
				table.remove(largeRadarUnits, i)
				break
			end
		end
	end
end

-- Keep caches updated
function widget:PlayerChanged(playerID)
	local oldAllyTeamID = myAllyTeamID
	rebuildAllowedTeams()
	if myAllyTeamID ~= oldAllyTeamID then
		rebuildMyAllyRadarUnits()
	end
end

function widget:UnitFinished(unitID, unitDefID, teamID)
	-- If we only want finished buildings; ensure it's registered (no harm if already present)
	addIfMyAllyRadar(unitID, unitDefID, teamID)
end

function widget:UnitDestroyed(unitID)
	removeUnitFromBucket(unitID)
end

function widget:UnitTaken(unitID, unitDefID, oldTeam, newTeam)
	removeUnitFromBucket(unitID)
	addIfMyAllyRadar(unitID, unitDefID, newTeam)
end

function widget:UnitGiven(unitID, unitDefID, newTeam, oldTeam)
	removeUnitFromBucket(unitID)
	addIfMyAllyRadar(unitID, unitDefID, newTeam)
end

local function drawRadarAt(x, y, z, range)
	radarTruthShader:SetUniform(
		"radarcenter_range",
		math.floor((x + 8) / (SHADERRESOLUTION * 2)) * (SHADERRESOLUTION * 2),
		y,
		math.floor((z + 8) / (SHADERRESOLUTION * 2)) * (SHADERRESOLUTION * 2),
		range
	)
end

function widget:DrawWorld()
	if Spring.IsGUIHidden() or (WG['topbar'] and WG['topbar'].showingQuit()) then
		return
	end

	if not radarTruthShader then return end

	-- Only show overlay if a radar tower is selected OR a radar build command is active
	local showOverlay = false
	if selectedRadarUnitID then
		showOverlay = true
	else
		local cmdID = select(2, Spring.GetActiveCommand())
		if cmdID and cmdID < 0 then
			local buildDefID = -cmdID
			if radarDefIDs[buildDefID] then
				showOverlay = true
			end
		end
	end
	if not showOverlay then return end

	gl.DepthTest(false)
	gl.Culling(GL.BACK)
	gl.Texture(0, "$heightmap")
	radarTruthShader:Activate()

	-- Draw small radars for my team
	if smallradVAO and #smallRadarUnits > 0 then
		for i = 1, #smallRadarUnits do
			local unitID = smallRadarUnits[i]
			if Spring.ValidUnitID(unitID) and not Spring.GetUnitIsDead(unitID) then
				local x, y, z = Spring.GetUnitPosition(unitID)
				local udid = Spring.GetUnitDefID(unitID)
				if x and udid then
					drawRadarAt(x, (y or 0) + (radaremitheight[udid] or radarYOffset), z, smallradarrange)
					smallradVAO:DrawElements(GL.TRIANGLES)
				end
			end
		end
	end

	-- Draw large radars for my team
	if largeradVAO and #largeRadarUnits > 0 then
		for i = 1, #largeRadarUnits do
			local unitID = largeRadarUnits[i]
			if Spring.ValidUnitID(unitID) and not Spring.GetUnitIsDead(unitID) then
				local x, y, z = Spring.GetUnitPosition(unitID)
				local udid = Spring.GetUnitDefID(unitID)
				if x and udid then
					drawRadarAt(x, (y or 0) + (radaremitheight[udid] or radarYOffset), z, largeradarrange)
					largeradVAO:DrawElements(GL.TRIANGLES)
				end
			end
		end
	end

	radarTruthShader:Deactivate()
	gl.Texture(0, false)
	gl.Culling(false)
	gl.DepthTest(true)
end

function widget:Shutdown()
	-- best-effort cleanup
	if radarTruthShader and radarTruthShader.Delete then radarTruthShader:Delete() end
	radarTruthShader = nil
	smallradVAO = nil
	largeradVAO = nil
end
