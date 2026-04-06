local widget = widget ---@type Widget
local Spring = Spring
local gl = gl
local GL = GL
local WG = WG
local Game = Game
local UnitDefs = UnitDefs
local widgetHandler = widgetHandler

function widget:GetInfo()
	return {
		name = "Sensor Ranges Radar Preview (All radars)",
		desc = "Shows raytraced radar coverage for all allied radar buildings (GL4)",
		author = "uBdead, Beherith",
		date = "2025.08.13",
		license = "Lua: GPLv2, GLSL: (c) Beherith (mysterme@gmail.com)",
		layer = 0,
		enabled = true,
	}
end

--------------------------------------------------------------------------------
-- Performance-tuned constants
--------------------------------------------------------------------------------
local SHADER_RESOLUTION = 32   -- grid cell size in elmos (2x coarser than original = 4x fewer vertices)
local RAYMARCH_STEPS = 40       -- ray-march steps per vertex (vs 112 original = ~3x cheaper)
local RADAR_Y_OFFSET = 50
local REFRESH_INTERVAL = 90    -- frames between full radar list refresh
local GL_KEEP = 0x1E00

--------------------------------------------------------------------------------
-- Engine API shortcuts
--------------------------------------------------------------------------------
local mathFloor = math.floor
local mathMax = math.max
local spGetMyAllyTeamID = Spring.GetMyAllyTeamID
local spGetTeamList = Spring.GetTeamList
local spGetTeamUnits = Spring.GetTeamUnits
local spGetUnitPosition = Spring.GetUnitPosition
local spGetUnitDefID = Spring.GetUnitDefID
local spIsGUIHidden = Spring.IsGUIHidden
local spGetActiveCommand = Spring.GetActiveCommand
local spGetSelectedUnits = Spring.GetSelectedUnits
local spGetGameFrame = Spring.GetGameFrame

local LuaShader = gl.LuaShader
local InstanceVBOTable = gl.InstanceVBOTable

--------------------------------------------------------------------------------
-- Radar unit definitions (built once at load time)
--------------------------------------------------------------------------------
local radarDefs = {} -- unitDefID -> { range, emitHeight }

for unitDefID, ud in pairs(UnitDefs) do
	if ud.radarDistance and ud.radarDistance > 0 and ud.isBuilding then
		radarDefs[unitDefID] = {
			range = ud.radarDistance,
			emitHeight = (ud.radarEmitHeight or 0) + RADAR_Y_OFFSET,
		}
	end
end

--------------------------------------------------------------------------------
-- Inline GLSL shaders
--
-- Performance notes vs original:
--   * Grid is 2x coarser (SHADER_RESOLUTION 32 vs 16) → 4x fewer vertices
--   * Ray-march uses 40 steps vs 112 → 2.8x fewer texture lookups per vertex
--   * HeightAt samples mip level 1 → cheaper texture reads
--   * Out-of-range vertices early-discard before ray-march loop
--   * Combined: ~10x reduction in texture lookups per radar
--------------------------------------------------------------------------------
local vsSrc = [[
#version 420
#line 10000

//__DEFINES__

layout(location = 0) in vec2 xyworld_xyfract;

uniform vec4 radarcenter_range; // x, y, z, range
uniform float resolution;
uniform sampler2D heightmapTex;

out float v_visible;

//__ENGINEUNIFORMBUFFERDEFS__

#line 11000

float heightAt(vec2 w) {
	vec2 uv = clamp(w, vec2(8.0), mapSize.xy - 8.0) / mapSize.xy;
	return max(0.0, textureLod(heightmapTex, uv, 1.0).x);
}

void main() {
	vec3 center = radarcenter_range.xyz;
	float range = radarcenter_range.w;

	vec3 pos;
	pos.xz = center.xz + xyworld_xyfract.xy * range;
	pos.y = heightAt(pos.xz);

	float dist = length(center.xz - pos.xz);

	// Early discard for vertices outside radar range — skip expensive ray-march
	if (dist > range) {
		v_visible = 0.0;
		gl_Position = vec4(0.0, 0.0, -2.0, 1.0);
		return;
	}

	// Ray-march toward radar center checking terrain occlusion
	vec3 toCenter = center - pos;
	vec3 step = toCenter / resolution;
	float obscured = 0.0;
	for (float i = 1.0; i < resolution; i += 1.0) {
		vec3 raypos = pos + step * i;
		float h = heightAt(raypos.xz);
		obscured = max(obscured, h - raypos.y);
		if (obscured >= 2.0) break;
	}

	v_visible = (obscured < 2.0) ? 1.0 : 0.0;
	pos.y += 0.15;
	gl_Position = cameraViewProj * vec4(pos, 1.0);
}
]]

local fsSrc = [[
#version 420
#line 20000

//__ENGINEUNIFORMBUFFERDEFS__

in float v_visible;
out vec4 fragColor;

void main() {
	if (v_visible < 0.5) discard;
	fragColor = vec4(0.0, 1.0, 0.0, 1.0);
}
]]

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------
local radarShader
local shaderSourceCache = {
	vsSrc = vsSrc,
	fsSrc = fsSrc,
	shaderName = "AlliedRadarCoverage GL4",
	uniformInt = { heightmapTex = 0 },
	uniformFloat = {
		radarcenter_range = { 0, 0, 0, 0 },
		resolution = { RAYMARCH_STEPS },
	},
	shaderConfig = {},
	forceupdate = true,
}

local rangeToVAO = {} -- radar range -> VAO (lazily created)
local alliedRadars = {} -- { unitID, range, emitHeight }[]
local lastRefreshFrame = -999

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

--- Check if the player is actively placing a radar building or has one selected.
local function isRadarContext()
	local cmdID = select(2, spGetActiveCommand())
	if cmdID and cmdID < 0 and radarDefs[-cmdID] then
		return true
	end
	local sel = spGetSelectedUnits()
	for i = 1, #sel do
		local udid = spGetUnitDefID(sel[i])
		if udid and radarDefs[udid] then
			return true
		end
	end
	return false
end

--- Return (or create) a VAO with a grid matching the given radar range.
local function getOrCreateVAO(range)
	if rangeToVAO[range] then return rangeToVAO[range] end
	local gridSize = mathMax(4, mathFloor(range / SHADER_RESOLUTION))
	local vbo = InstanceVBOTable.makePlaneVBO(1, 1, gridSize)
	local ibo = InstanceVBOTable.makePlaneIndexVBO(gridSize, gridSize, true)
	local vao = gl.GetVAO()
	vao:AttachVertexBuffer(vbo)
	vao:AttachIndexBuffer(ibo)
	rangeToVAO[range] = vao
	return vao
end

--- Scan all allied teams for radar buildings.
local function refreshAlliedRadars()
	alliedRadars = {}
	local myAlly = spGetMyAllyTeamID()
	for _, teamID in ipairs(spGetTeamList(myAlly)) do
		for _, unitID in ipairs(spGetTeamUnits(teamID)) do
			local udid = spGetUnitDefID(unitID)
			if udid then
				local def = radarDefs[udid]
				if def then
					alliedRadars[#alliedRadars + 1] = {
						unitID = unitID,
						range = def.range,
						emitHeight = def.emitHeight,
					}
				end
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Widget lifecycle
--------------------------------------------------------------------------------
function widget:Initialize()
	if not gl.CreateShader then
		widgetHandler:RemoveWidget()
		return
	end
	radarShader = LuaShader.CheckShaderUpdates(shaderSourceCache)
	if not radarShader then
		Spring.Echo("[AlliedRadarCoverage] Shader compilation failed, removing widget.")
		widgetHandler:RemoveWidget()
		return
	end
	refreshAlliedRadars()
end

function widget:Shutdown()
end

--------------------------------------------------------------------------------
-- Drawing: stencil-based union rendering
--
-- Pass 1: For each radar, draw its ray-marched coverage mesh into the stencil
--         buffer with color writes off. Visible fragments write stencil=1.
--         Overlapping radars naturally form a union (ALWAYS pass, write 1).
-- Pass 2: Draw two ground quads testing stencil:
--         stencil==1 → green (covered), stencil==0 → red (uncovered)
--------------------------------------------------------------------------------
function widget:DrawWorld()
	if not isRadarContext() then return end
	if spIsGUIHidden() or (WG['topbar'] and WG['topbar'].showingQuit()) then return end

	-- Periodic refresh of radar list
	local frame = spGetGameFrame()
	if frame - lastRefreshFrame > REFRESH_INTERVAL then
		refreshAlliedRadars()
		lastRefreshFrame = frame
	end
	if #alliedRadars == 0 then return end

	local snap = SHADER_RESOLUTION * 2

	------------------------------------------------------------------------
	-- Pass 1: Stencil — mark radar-covered ground
	------------------------------------------------------------------------
	gl.DepthTest(false)
	gl.Culling(GL.BACK)
	gl.Texture(0, "$heightmap")
	radarShader:Activate()
	radarShader:SetUniform("resolution", RAYMARCH_STEPS)

	gl.Clear(GL.STENCIL_BUFFER_BIT)
	gl.StencilTest(true)
	gl.StencilMask(1)
	gl.StencilFunc(GL.ALWAYS, 1, 1)
	gl.StencilOp(GL_KEEP, GL_KEEP, GL.REPLACE)
	gl.ColorMask(false, false, false, false)
	gl.Blending(false)

	for i = 1, #alliedRadars do
		local r = alliedRadars[i]
		local x, y, z = spGetUnitPosition(r.unitID)
		if x then
			radarShader:SetUniform("radarcenter_range",
				mathFloor((x + 8) / snap) * snap,
				(y or 0) + r.emitHeight,
				mathFloor((z + 8) / snap) * snap,
				r.range
			)
			getOrCreateVAO(r.range):DrawElements(GL.TRIANGLES)
		end
	end

	radarShader:Deactivate()
	gl.Texture(0, false)

	------------------------------------------------------------------------
	-- Pass 2: Color overlay via stencil test (two cheap ground quads)
	------------------------------------------------------------------------
	gl.ColorMask(true, true, true, true)
	gl.Blending(GL.SRC_ALPHA, GL.ONE_MINUS_SRC_ALPHA)
	gl.StencilMask(0)

	-- Green where covered (stencil == 1)
	gl.StencilFunc(GL.EQUAL, 1, 1)
	gl.Color(0, 1, 0, 0.10)
	gl.DrawGroundQuad(0, 0, Game.mapSizeX, Game.mapSizeZ)

	-- Red where uncovered (stencil == 0)
	gl.StencilFunc(GL.EQUAL, 0, 1)
	gl.Color(1, 0, 0, 0.10)
	gl.DrawGroundQuad(0, 0, Game.mapSizeX, Game.mapSizeZ)

	------------------------------------------------------------------------
	-- Cleanup
	------------------------------------------------------------------------
	gl.StencilTest(false)
	gl.StencilMask(255)
	gl.Color(1, 1, 1, 1)
	gl.Culling(false)
	gl.DepthTest(true)
end
