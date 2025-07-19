local widget = widget ---@type Widget

function widget:GetInfo()
  return {
    name = "Point Tracker Advanced",
    desc = "Allows for customizable point tracking.",
    author = "uBdead",
    date = "2025-07-12",
    license = "GNU GPL, v2 or later",
    layer = 19, -- below most GUI elements, which generally go up to 10
    enabled = true
  }
end

local timeToLive = 330
local lineWidth = 1.0

local getCurrentMiniMapRotationOption = VFS.Include("luaui/Include/minimap_utils.lua").getCurrentMiniMapRotationOption

----------------------------------------------------------------
--speedups
----------------------------------------------------------------
local ArePlayersAllied = Spring.ArePlayersAllied
local GetPlayerInfo = Spring.GetPlayerInfo
local GetTeamColor = Spring.GetTeamColor
local GetSpectatingState = Spring.GetSpectatingState

local glLineWidth = gl.LineWidth

----------------------------------------------------------------
--vars
----------------------------------------------------------------
local mapPoints = {}
local myPlayerID
local enabled = true
local instanceIDgen = 1

----------------------------------------------------------------
--local functions
----------------------------------------------------------------
local function GetPlayerColor(playerID)
  local _, _, isSpec, teamID = GetPlayerInfo(playerID, false)
  if isSpec then
    return GetTeamColor(Spring.GetGaiaTeamID())
  end
  if not teamID then
    return nil
  end
  return GetTeamColor(teamID)
end

local mapMarkInstanceVBO = nil
local mapMarkShader= nil

local LuaShader = gl.LuaShader
local InstanceVBOTable = gl.InstanceVBOTable

local popElementInstance  = InstanceVBOTable.popElementInstance
local pushElementInstance = InstanceVBOTable.pushElementInstance
local drawInstanceVBO     = InstanceVBOTable.drawInstanceVBO


local function ClearPoints()
  mapPoints = {}
  InstanceVBOTable.clearInstanceTable(mapMarkInstanceVBO)
end

local shaderParams = {
    MAPMARKERSIZE = 0.035,
    LIFEFRAMES = timeToLive,
    ANIM_BASESIZE = 1.5, -- start large and visible
    ANIM_MIN = 0.01,     -- much smaller minimum size for fast oscillation
    ANIM_MAX = 0.1,     -- small max size for fast oscillation
    ANIM_PHASE1_FRAC = 0.20, -- fraction of lifetime for initial shrink
    ANIM_ROT_SPEED = 8.0 * math.pi, -- radians per normalized lifetime
    NUM_BOXES = 3,       -- number of staggered boxes
}

local vsSrc =
[[
#version 420

layout (location = 0) in vec2 position;
layout (location = 1) in vec4 worldposradius;
layout (location = 2) in vec4 colorlife;

uniform float isMiniMap;

// Animation uniforms
uniform float ANIM_BASESIZE;
uniform float ANIM_MIN;
uniform float ANIM_MAX;
uniform float ANIM_PHASE1_FRAC;
uniform float ANIM_ROT_SPEED;
uniform float NUM_BOXES;
uniform float minimapAspect;

out DataVS {
  vec4 blendedcolor;
};

//__DEFINES__
//__ENGINEUNIFORMBUFFERDEFS__

#line 10000
void main()
{
  // Convert from world space to screenspace
  vec4 worldPosInCamSpace;
  if (isMiniMap > 0.5) {
    worldPosInCamSpace = mmDrawViewProj * vec4(worldposradius.xyz, 1.0);
  } else {
    worldPosInCamSpace = cameraViewProj * vec4(worldposradius.xyz, 1.0);
  }
  // Project to NDC
  vec3 ndc = worldPosInCamSpace.xyz / worldPosInCamSpace.w;
  ndc.xy = clamp(ndc.xy, -0.98, 0.98); // keep slightly inside screen bounds
  vec2 screenpos = ndc.xy;

  // Calculate aspect ratio for stretching
  float aspect;
  if (isMiniMap > 0.5) {
    aspect = minimapAspect; // minimap aspect ratio, set as uniform from Lua
  } else {
    aspect = timeInfo.z / timeInfo.y; // main viewport aspect ratio
  }

  // Animation timing
  float marker_age = (timeInfo.x + timeInfo.w) - colorlife.w;
  float marker_frac = clamp(marker_age / LIFEFRAMES, 0.0, 1.0);
  
  // Calculate which box this vertex belongs to (0, 1, or 2)
  int box_id = gl_InstanceID % int(float(NUM_BOXES));
  float box_offset = float(box_id) / float(NUM_BOXES);
  
  // All boxes start big: no stagger for animation phase
  float size;
  float alpha = 1.0;
  float phase1_t = clamp(marker_frac / ANIM_PHASE1_FRAC, 0.0, 1.0);
  float eased_t = 1.0 - pow(1.0 - phase1_t, 3.0);
  float phase1_size = mix(float(ANIM_BASESIZE), ANIM_MIN, eased_t);
  float phase1_alpha = 1.0 - phase1_t * 0.3;

  float phase2_t = clamp((marker_frac - ANIM_PHASE1_FRAC) / (1.0 - ANIM_PHASE1_FRAC), 0.0, 1.0);
  float osc_freq = 8.0; // much faster oscillation in phase 2
  float osc = sin(phase2_t * 3.14159 * osc_freq);
  osc = osc * 0.5 + 0.5;
  float phase2_size = mix(ANIM_MIN, ANIM_MAX, osc);
  float phase2_alpha = 1.0 - pow(phase2_t, 2.0);

  // Blend the two phases at the transition point to avoid jumps
  if (marker_frac < ANIM_PHASE1_FRAC) {
    size = phase1_size;
    alpha = phase1_alpha;
  } else {
    // Blend at the transition for smoothness
    float blend_t = smoothstep(0.0, 0.05, phase2_t); // small blend window
    size = mix(phase1_size, phase2_size, blend_t);
    alpha = mix(phase1_alpha, phase2_alpha, blend_t);
  }
  // Continuous rotation for all boxes, but with different speeds
  float rot_speed_multiplier = 1.0 + float(box_id) * 0.3;
  float rot = marker_frac * ANIM_ROT_SPEED * rot_speed_multiplier;
  
  // Apply rotation matrix
  float c = cos(rot);
  float s = sin(rot);
  vec2 rotated = vec2(
    position.x * c - position.y * s,
    position.x * s + position.y * c
  );
  
  // Scale the rotated position
  // Apply per-box size multiplier: 1.0, 0.8, 0.6 for box_id 0, 1, 2
  float box_size_multiplier = 1.0 - float(box_id) * 0.25;
  rotated.x *= size * aspect * box_size_multiplier; // Apply aspect ratio correction to X and box size
  rotated.y *= size * box_size_multiplier;
  
  // Add the animated vertex offset in screenspace
  screenpos += rotated.xy;
  gl_Position = vec4(screenpos, 0.0, 1.0);
  
  // Set color with proper alpha based on box and animation phase
  vec3 baseColor = colorlife.rgb;
  vec3 boxColor;
  if (box_id == 0) {
    // Very light version: blend with white
    boxColor = mix(baseColor, vec3(1.0, 1.0, 1.0), 0.5);
  } else if (box_id == 1) {
    // Actual player color
    boxColor = baseColor;
  } else {
    // Very dark version: blend with black
    boxColor = mix(baseColor, vec3(0.0, 0.0, 0.0), 0.5);
  }
  float box_alpha_multiplier = 1.0 - float(box_id) * 0.2; // make later boxes slightly more transparent
  blendedcolor = vec4(boxColor, alpha * box_alpha_multiplier * (1.0 - marker_frac * 0.3));
}
]]

local fsSrc =
[[
#version 420
#line 20000

//__DEFINES__
//__ENGINEUNIFORMBUFFERDEFS__

//#extension GL_ARB_uniform_buffer_object : require
//#extension GL_ARB_shading_language_420pack: require

in DataVS {	vec4 blendedcolor; };

out vec4 fragColor;
void main(void) { fragColor = vec4(blendedcolor.rgba); }
]]

local function goodbye(reason)
  Spring.Echo("Point Tracker GL4 widget exiting with reason: "..reason)
  widgetHandler:RemoveWidget()
end

function makePingVBO()
  -- makes points with xyzw GL.LINES
  local markerVBO = gl.GetVBO(GL.ARRAY_BUFFER,false)
  if markerVBO == nil then return nil end

  local VBOLayout = {	 {id = 0, name = "position_xy", size = 2}, 	}
  local VBOData = { -- All 4 edges of a square (as lines)
    -1, -1,  -1,  1,  -- left edge
    -1,  1,   1,  1,  -- top edge
     1,  1,   1, -1,  -- right edge
     1, -1,  -1, -1,  -- bottom edge
  }
  markerVBO:Define(	#VBOData/2,	VBOLayout)
  markerVBO:Upload(VBOData)
  return markerVBO, #VBOData/2
end

local function initGL4()

  local engineUniformBufferDefs = LuaShader.GetEngineUniformBufferDefs()
  vsSrc = vsSrc:gsub("//__ENGINEUNIFORMBUFFERDEFS__", engineUniformBufferDefs)
  fsSrc = fsSrc:gsub("//__ENGINEUNIFORMBUFFERDEFS__", engineUniformBufferDefs)
  mapMarkShader =  LuaShader(
    {
      vertex = vsSrc:gsub("//__DEFINES__", LuaShader.CreateShaderDefinesString(shaderParams)),
      fragment = fsSrc:gsub("//__DEFINES__", LuaShader.CreateShaderDefinesString(shaderParams)),
      uniformInt = {
        },
      uniformFloat = {
        isMiniMap = 0,
        ANIM_BASESIZE = shaderParams.ANIM_BASESIZE,
        ANIM_MIN = shaderParams.ANIM_MIN,
        ANIM_MAX = shaderParams.ANIM_MAX,
        ANIM_PHASE1_FRAC = shaderParams.ANIM_PHASE1_FRAC,
        ANIM_ROT_SPEED = shaderParams.ANIM_ROT_SPEED,
        NUM_BOXES = shaderParams.NUM_BOXES,
      },
    },
    "mapMarkShader GL4"
  )
  shaderCompiled = mapMarkShader
  mapMarkShader:Initialize()
  if not shaderCompiled then goodbye("Failed to compile mapMarkShader GL4 ") end
  local markerVBO,numVertices = makePingVBO() --xyzw
  local mapMarkInstanceVBOLayout = {
      {id = 1, name = 'posradius', size = 4}, -- posradius
      {id = 2, name = 'colorlife', size = 4}, --  color + startgameframe
    }
  mapMarkInstanceVBO = InstanceVBOTable.makeInstanceVBOTable(mapMarkInstanceVBOLayout, 32, "mapMarkInstanceVBO")
  mapMarkInstanceVBO.numVertices = numVertices
  mapMarkInstanceVBO.vertexVBO = markerVBO
  mapMarkInstanceVBO.VAO = InstanceVBOTable.makeVAOandAttach(mapMarkInstanceVBO.vertexVBO, mapMarkInstanceVBO.instanceVBO)
  mapMarkInstanceVBO.primitiveType = GL.LINES

  if false then -- testing
    pushElementInstance(mapMarkInstanceVBO,	{	200, 400, 200, 2000, 1, 0, 1, 1000000 },	nil, true)
  end
end

--------------------------------------------------------------------------------
-- Draw Iteration
--------------------------------------------------------------------------------
function DrawMapMarksWorld(isMiniMap)
  if mapMarkInstanceVBO.usedElements > 0 then
    glLineWidth(lineWidth)
    mapMarkShader:Activate()
    mapMarkShader:SetUniform("isMiniMap",isMiniMap)
    if isMiniMap > 0.5 then
      -- Calculate minimap aspect ratio (width/height), avoid div0
      local mmW, mmH = Spring.GetMiniMapGeometry()
      local aspect = 1.0
      if mmH and mmH ~= 0 then
        aspect = mmW / mmH
      end
      mapMarkShader:SetUniform("minimapAspect", aspect)
    else
      mapMarkShader:SetUniform("minimapAspect", 1.0)
    end
    drawInstanceVBO(mapMarkInstanceVBO)
    mapMarkShader:Deactivate()
  end
end

----------------------------------------------------------------
--callins
----------------------------------------------------------------
function widget:Initialize()
  if not gl.CreateShader then -- no shader support, so just remove the widget itself, especially for headless
    widgetHandler:RemoveWidget()
    return
  end
  initGL4()
  myPlayerID = Spring.GetMyPlayerID()
  WG.PointTracker = {
    ClearPoints = ClearPoints,
  }

  Spring.SendCommands("minimap drawnotes 0") -- disable minimap notes (not merged in engine yet)
end

function widget:Shutdown()
  WG.PointTracker = nil
end

-- Restore the minimap drawnotes on exit
function widget:GameOver()
  Spring.SendCommands("minimap drawnotes 1")
end

function widget:DrawScreen()
  if not enabled then
    return
  end
  DrawMapMarksWorld(0)
end

function widget:MapDrawCmd(playerID, cmdType, px, py, pz, label)

  local spectator, fullView = GetSpectatingState()
  local _, _, _, playerTeam = GetPlayerInfo(playerID, false)
  if label == "Start " .. playerTeam
    or cmdType ~= "point"
    or not (ArePlayersAllied(myPlayerID, playerID) or (spectator and fullView)) then
    return
  end
  
  local r, g, b = GetPlayerColor(playerID)
  local gf = Spring.GetGameFrame()
  
  -- Create 3 staggered boxes for the radar ping effect
  local instanceIDs = {}
  for i = 1, shaderParams.NUM_BOXES do
    instanceIDgen = instanceIDgen + 1
    
    pushElementInstance(
        mapMarkInstanceVBO,
        {
          px, py, pz, 1.0,
          r, g, b, gf
        },
        instanceIDgen, -- key, generate me one if nil
        true -- update existing
      )
    
    instanceIDs[i] = instanceIDgen
  end
  
  if mapPoints[gf] then
    for i = 1, #instanceIDs do
      mapPoints[gf][#mapPoints[gf] + 1] = instanceIDs[i]
    end
  else
    mapPoints[gf] = instanceIDs
  end
end

function widget:GameFrame(n)
  if mapPoints[n-timeToLive] then
    for i, instanceID in ipairs(mapPoints[n-timeToLive]) do
      popElementInstance(mapMarkInstanceVBO,instanceID)
    end
  end
end

function widget:DrawInMiniMap(sx, sy)
  if not enabled then return	end
  -- this fixes drawing on only 1 quadrant of minimap as pwe
  gl.ClipDistance ( 1, false)
  gl.ClipDistance ( 3, false)
  DrawMapMarksWorld(1)
end

function widget:ClearMapMarks()
  ClearPoints()
end
