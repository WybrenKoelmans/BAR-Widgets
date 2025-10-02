local widget = widget

function widget:GetInfo()
	return {
		name      = "More Range Indicators",
		desc      = "Shows vision range indicators with shader rendering.",
		author    = "uBdead",
		date      = "2025-09-14",
		license   = "GNU GPL, v2 or later",
		layer     = 0,
		enabled   = true,
        depends   = {'gl4'}
	}
end

local minSightDistance = 100
local minJammerDistance = 63
local rangecorrectionelmos = 16
local rangeLineWidth = 4.5
local lineScale = 1
local circleSegments = 62
local SHADERRESOLUTION = 16

local visionColor = { 0.9, 0.9, 0.9, 0.24 }
local jammerColor = { 1.0, 0.35, 0.0, 0.35 }
local opacity = 0.7

-- Shader variables
local LuaShader = gl.LuaShader
local InstanceVBOTable = gl.InstanceVBOTable
local visionShader = nil
local visionVAOs = {}
local mousepos = { 0, 0, 0 }

-- Track unit types with vision ranges
local cmdidtorange = {}
local unitVisionHeight = {}
local selectedUnits = {} -- Track selected units

-- Initialize unit data with more accurate height calculation
for unitDefID, unitDef in pairs(UnitDefs) do
	if unitDef.sightDistance and unitDef.sightDistance > minSightDistance then
		cmdidtorange[-1 * unitDefID] = unitDef.sightDistance - rangecorrectionelmos
		-- Use only losHeight, matching engine behavior
		unitVisionHeight[-1 * unitDefID] = unitDef.losHeight or 20
	end
end

-- Shader setup
local shaderConfig = {}
local vsSrcPath = "LuaUI/Widgets/gui_more_range_indicators/sensor_ranges_vision_preview.vert.glsl"
local fsSrcPath = "LuaUI/Widgets/gui_more_range_indicators/sensor_ranges_vision_preview.frag.glsl"

local shaderSourceCache = {
	vssrcpath = vsSrcPath,
	fssrcpath = fsSrcPath,
	shaderName = "visionPreviewShader GL4",
	uniformInt = {
		heightmapTex = 0,
	},
	uniformFloat = {
		visioncenter_range = { 2000, 100, 2000, 2000 },
		resolution = { 128 }, -- Match radar resolution for consistency
	},
	shaderConfig = shaderConfig,
}

local function goodbye(reason)
	Spring.Echo("visionPreviewShader GL4 widget exiting with reason: " .. reason)
	widgetHandler:RemoveWidget()
end

local function initgl4()
	visionShader = LuaShader.CheckShaderUpdates(shaderSourceCache)
	
	if not visionShader then
		goodbye("Failed to compile visionPreviewShader GL4")
		return false
	end
	
	-- Create VAOs for different vision ranges
	local commonRanges = {}
	for cmdID, range in pairs(cmdidtorange) do
		if not commonRanges[range] then
			commonRanges[range] = true
			local vbo, vbosize = InstanceVBOTable.makePlaneVBO(1, 1, range / SHADERRESOLUTION)
			local ibo, ibosize = InstanceVBOTable.makePlaneIndexVBO(range / SHADERRESOLUTION, range / SHADERRESOLUTION, true)
			local vao = gl.GetVAO()
			vao:AttachVertexBuffer(vbo)
			vao:AttachIndexBuffer(ibo)
			visionVAOs[range] = vao
		end
	end
	
	return true
end

function widget:Initialize()
	if not gl.CreateShader then
		widgetHandler:RemoveWidget()
		return
	end
	
	if not initgl4() then
		return
	end
end

function widget:SelectionChanged(selection)
	selectedUnits = {}
	for i = 1, #selection do
		local unitID = selection[i]
		local unitDefID = Spring.GetUnitDefID(unitID)
		if unitDefID then
			local unitDef = UnitDefs[unitDefID]
			if unitDef and unitDef.sightDistance and unitDef.sightDistance > minSightDistance then
				selectedUnits[unitID] = {
					defID = unitDefID,
					sightRange = unitDef.sightDistance - rangecorrectionelmos,
					jammerRange = unitDef.radarDistanceJam and unitDef.radarDistanceJam > minJammerDistance and (unitDef.radarDistanceJam - rangecorrectionelmos) or nil
				}
			end
		end
	end
end

local function DrawCircle(x, y, z, radius, color)
	gl.Color(color[1], color[2], color[3], color[4])
	gl.LineWidth(rangeLineWidth * lineScale * 1.2)
	gl.DepthTest(true)
	gl.PushMatrix()
	gl.Translate(x, y + 2, z)
	gl.Scale(radius, 1, radius)
	gl.BeginEnd(GL.LINE_LOOP, function()
		for i = 1, circleSegments do
			local theta = (2 * math.pi) * (i-1) / circleSegments
			gl.Vertex(math.cos(theta), 0, math.sin(theta))
		end
	end)
	gl.PopMatrix()
	gl.LineWidth(1.0)
	gl.Color(1,1,1,opacity)
end

local function DrawVisionRange(x, y, z, range, cmdID)
	if not visionShader or not visionVAOs[range] then
		-- Fallback to circle drawing
		DrawCircle(x, y, z, range, visionColor)
		return
	end
	
	local visionHeight = unitVisionHeight[cmdID] or 50
	
	gl.DepthTest(false)
	gl.Culling(GL.BACK)
	gl.Texture(0, "$heightmap")
	
	visionShader:Activate()
	visionShader:SetUniform("visioncenter_range",
		math.floor((x + 8) / (SHADERRESOLUTION * 2)) * (SHADERRESOLUTION * 2),
		y + visionHeight, -- Use unit-specific vision height
		math.floor((z + 8) / (SHADERRESOLUTION * 2)) * (SHADERRESOLUTION * 2),
		range
	)
	visionShader:SetUniform("resolution", 128) -- Match radar resolution
	
	visionVAOs[range]:DrawElements(GL.TRIANGLES)
	
	visionShader:Deactivate()
	gl.Texture(0, false)
	gl.Culling(false)
	gl.DepthTest(true)
	
	-- (Removed drawing of unit height text)
end

function widget:DrawWorld()
	-- Do not show vision for selected units anymore
	
	-- Build preview for vision ranges
	local _, cmdID, _, _, cmdDesc = Spring.GetActiveCommand()
	if cmdID and cmdID < 0 then -- build command
		local mx, my = Spring.GetMouseState()
		local traceType, data = Spring.TraceScreenRay(mx, my, true, true)
		if traceType == "ground" and data and data[1] and data[3] then
			local unitDefID = -cmdID
			local ud = UnitDefs[unitDefID]
			if ud then
				local rawX, rawZ = data[1], data[3]
				
				-- Get the actual build position with grid snapping
				local buildX, buildY, buildZ = Spring.Pos2BuildPos(unitDefID, rawX, Spring.GetGroundHeight(rawX, rawZ), rawZ)
				
				-- Use the snapped position if available, otherwise fallback to manual snapping
				local x, y, z
				if buildX and buildY and buildZ then
					x, y, z = buildX, buildY, buildZ
				else
					-- Manual grid snapping fallback
					local gridSize = 8
					x = math.floor(rawX / gridSize + 0.5) * gridSize
					z = math.floor(rawZ / gridSize + 0.5) * gridSize
					
					-- Center the building on its footprint
					if ud.xsize and ud.xsize % 2 == 0 then
						x = x + gridSize / 2
					end
					if ud.zsize and ud.zsize % 2 == 0 then
						z = z + gridSize / 2
					end
					y = Spring.GetGroundHeight(x, z)
				end
				
				-- Draw vision range with shader
				if cmdidtorange[cmdID] then
					DrawVisionRange(x, y, z, cmdidtorange[cmdID], cmdID)
				end
				
				-- Draw jammer range with circle (no shader for this yet)
				if ud.radarDistanceJam and ud.radarDistanceJam > minJammerDistance then
					local range = ud.radarDistanceJam - rangecorrectionelmos
					DrawCircle(x, y, z, range, jammerColor)
				end
			end
		end
	end
end

function widget:Shutdown()
	if visionShader then
		visionShader:Delete()
	end
	for _, vao in pairs(visionVAOs) do
		if vao then
			vao:Delete()
		end
	end
end