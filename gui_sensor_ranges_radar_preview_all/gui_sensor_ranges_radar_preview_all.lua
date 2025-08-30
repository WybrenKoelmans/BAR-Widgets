local widget = widget
-- Localize global tables for linter/runtime
local Spring = Spring
local gl = gl
local GL = GL
local WG = WG
local Game = Game
local UnitDefs = UnitDefs
local widgetHandler = widgetHandler
-- Stencil constants (mirroring usage in gui_attackrange_gl4)
local GL_KEEP = 0x1E00 -- GL.KEEP numeric
local GL_REPLACE = GL.REPLACE

local function get_lua_dirname()
	-- Dynamically determine the directory of this script for portability
	local info = debug and debug.getinfo and debug.getinfo(1, "S")
	if info and info.source then
		local src = info.source
		if src:sub(1,1) == "@" then src = src:sub(2) end -- remove leading @
		-- Normalize to VFS path (LuaUI/Widgets/...) if possible
		local vfs = src:match("(LuaUI/Widgets/.*/)")
		if vfs then return vfs end
		-- Fallback: just return directory part
		return src:match("(.*/)") or "./"
	end
	return "./"
end
local LUA_DIRNAME = get_lua_dirname()

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

-- Helper: check if we are building or have selected a radar building
local function IsRadarBuildOrSelected()
	-- Check active build command
	local spGetActiveCommand = Spring.GetActiveCommand
	local spGetSelectedUnits = Spring.GetSelectedUnits
	local spGetUnitDefID = Spring.GetUnitDefID
	local cmdID = select(2, spGetActiveCommand())
	if cmdID and cmdID < 0 then
		local unitDefID = -cmdID
		local ud = UnitDefs[unitDefID]
		if ud and ud.radarDistance and ud.radarDistance > 0 and ud.isBuilding then
			return true
		end
	end
	-- Check selected units
	local selected = spGetSelectedUnits()
	for i = 1, #selected do
		local unitDefID = spGetUnitDefID(selected[i])
		local ud = UnitDefs[unitDefID]
		if ud and ud.radarDistance and ud.radarDistance > 0 and ud.isBuilding then
			return true
		end
	end
	return false
end
local SHADER_RESOLUTION = 16 -- matches mip resolution in original widget
local UPDATE_RADAR_LIST_FRAMES = 45
local radarYOffset = 50

--------------------------------------------------------------------------------
-- Locals & engine refs
--------------------------------------------------------------------------------
local spGetMyAllyTeamID = Spring.GetMyAllyTeamID
local spGetTeamList = Spring.GetTeamList
local spGetTeamUnits = Spring.GetTeamUnits
local spGetUnitPosition = Spring.GetUnitPosition
local spGetUnitDefID = Spring.GetUnitDefID
local spIsGUIHidden = Spring.IsGUIHidden

local LuaShader = gl.LuaShader
local InstanceVBOTable = gl.InstanceVBOTable

local radarShader
local shaderSourceCache = {
	vssrcpath = LUA_DIRNAME .. "sensor_ranges_radar_preview_all.vert.glsl",
	fssrcpath = LUA_DIRNAME .. "sensor_ranges_radar_preview_all.frag.glsl",
	shaderName = "AlliedRadarUnion GL4",
	uniformInt = { heightmapTex = 0 },
	uniformFloat = { radarcenter_range = { 0,0,0,0 }, resolution = { 128 }, },
	shaderConfig = {},
}

-- Dynamic VAOs per radar range (so we don't assume only two sizes)
local rangeToVAO = {}
local rangeToGridSize = {}

-- Live radar instances list
local alliedRadars = {}
local lastRadarUpdate = 0

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------
local function goodbye(reason)
	Spring.Echo("[AlliedRadarUnion] exiting: " .. reason)
	widgetHandler:RemoveWidget()
end

local function getOrCreateVAO(range)
	local vao = rangeToVAO[range]
	if vao then return vao end
	local gridsize = math.max(4, math.floor(range / SHADER_RESOLUTION))
	local vbo, _ = InstanceVBOTable.makePlaneVBO(1, 1, gridsize)
	local ibo, _ = InstanceVBOTable.makePlaneIndexVBO(gridsize, gridsize, true)
	vao = gl.GetVAO()
	vao:AttachVertexBuffer(vbo)
	vao:AttachIndexBuffer(ibo)
	rangeToVAO[range] = vao
	rangeToGridSize[range] = gridsize
	return vao
end

local function refreshAlliedRadars()
	alliedRadars = {}
	local myAllyTeam = spGetMyAllyTeamID()
	for _, teamID in ipairs(spGetTeamList(myAllyTeam)) do
		for _, unitID in ipairs(spGetTeamUnits(teamID)) do
			local udid = spGetUnitDefID(unitID)
			if udid then
				local ud = UnitDefs[udid]
				if ud and ud.radarDistance and ud.radarDistance > 0 and ud.isBuilding then
					alliedRadars[#alliedRadars+1] = {
						unitID = unitID,
						range = ud.radarDistance,
						emitHeight = (ud.radarEmitHeight or 0) + radarYOffset
					}
				end
			end
		end
	end
end

--------------------------------------------------------------------------------
-- GL4 init
--------------------------------------------------------------------------------
local function initGL4()
	radarShader = LuaShader.CheckShaderUpdates(shaderSourceCache)
	if not radarShader then
		goodbye("shader compile fail")
		return
	end
end

--------------------------------------------------------------------------------
-- Widget lifecycle
--------------------------------------------------------------------------------
function widget:Initialize()
	if not gl.CreateShader then
		goodbye("No shader support")
		return
	end
	initGL4()
	refreshAlliedRadars()
end

function widget:Shutdown()
	-- cleanup handled by engine GC
end

--------------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------------
function widget:DrawWorld()
	if not IsRadarBuildOrSelected() then return end
	if spIsGUIHidden() or (WG['topbar'] and WG['topbar'].showingQuit()) then return end

	local frame = Spring.GetGameFrame()
	if frame - lastRadarUpdate > UPDATE_RADAR_LIST_FRAMES then
		refreshAlliedRadars()
		lastRadarUpdate = frame
	end
	if #alliedRadars == 0 then return end

	-- Stencil pass: mark union of unobscured radar coverage with value 1
	gl.DepthTest(false)
	gl.Culling(GL.BACK)
	gl.Texture(0, "$heightmap")
	radarShader:Activate()
	radarShader:SetUniform("resolution", 112)

	gl.Clear(GL.STENCIL_BUFFER_BIT)
	gl.StencilTest(true)
	gl.StencilMask(1)               -- allow writing first bit
	gl.StencilFunc(GL.ALWAYS, 1, 1) -- always pass stencil test
	gl.StencilOp(GL_KEEP, GL_KEEP, GL_REPLACE) -- write ref (1) where fragment passes & not discarded
	gl.ColorMask(false,false,false,false) -- no color writes this pass
	gl.Blending(false)

	for i = 1, #alliedRadars do
		local r = alliedRadars[i]
		local x, y, z = spGetUnitPosition(r.unitID)
		if x then
			local range = r.range
			local vao = getOrCreateVAO(range)
			local snap = (SHADER_RESOLUTION * 2)
			radarShader:SetUniform("radarcenter_range",
				math.floor((x + 8)/snap)*snap,
				(y or 0) + r.emitHeight,
				math.floor((z + 8)/snap)*snap,
				range
			)
			vao:DrawElements(GL.TRIANGLES)
		end
	end

	radarShader:Deactivate()
	gl.Texture(0,false)

	-- Color pass: draw red where stencil == 0 (uncovered), green where stencil == 1 (covered)
	gl.ColorMask(true,true,true,true)
	gl.Blending(GL.SRC_ALPHA, GL.ONE_MINUS_SRC_ALPHA)

	-- Red (uncovered): stencil value 0
	gl.StencilFunc(GL.EQUAL, 0, 1)
	gl.StencilMask(0) -- don't modify stencil now
	gl.Color(1,0,0,0.10)
	gl.DrawGroundQuad(0,0, Game.mapSizeX, Game.mapSizeZ)

	-- Green (covered): stencil value 1
	gl.StencilFunc(GL.EQUAL, 1, 1)
	gl.Color(0,1,0,0.10)
	gl.DrawGroundQuad(0,0, Game.mapSizeX, Game.mapSizeZ)

	-- Cleanup stencil state
	gl.StencilTest(false)
	gl.StencilMask(255)
	gl.Culling(false)
	gl.DepthTest(true)
end

--------------------------------------------------------------------------------
-- Debug / hot reload support: recompile shader if files changed
--------------------------------------------------------------------------------
function widget:Update(dt)
	-- Hot reload shader sources if they changed on disk.
	local maybe = LuaShader.CheckShaderUpdates(shaderSourceCache)
	if maybe then
		radarShader = maybe
	end
end
