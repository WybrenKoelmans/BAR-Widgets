#version 420
// Combined Allied Radar Coverage Vertex Shader (c) Beherith, modifications for multi-radar union by uBdead
// Renders unobscured radar coverage for a single radar instance (one draw call per radar) – union is formed by overdrawing.

//__DEFINES__

layout (location = 0) in vec2 xyworld_xyfract;
uniform vec4 radarcenter_range;  // x y z range
uniform float resolution;  // how many steps are done

uniform sampler2D heightmapTex;

out DataVS {
	vec4 worldPos; // pos
	vec4 centerposrange;
	float unobscured; // 1 if unobscured else 0
};

//__ENGINEUNIFORMBUFFERDEFS__

float heightAtWorldPos(vec2 w){
	vec2 uvhm = vec2(clamp(w.x,8.0,mapSize.x-8.0),clamp(w.y,8.0, mapSize.y-8.0))/ mapSize.xy;
	return max(0.0, textureLod(heightmapTex, uvhm, 0.0).x);
}

void main() {
	// Build world position for this sample point inside the radar disc
	vec4 pointWorldPos = vec4(0.0);
	vec3 radarMidPos = radarcenter_range.xyz + vec3(16.0, 0.0, 16.0); // keep original offset
	pointWorldPos.xz = (radarcenter_range.xz + (xyworld_xyfract.xy * radarcenter_range.w));
	pointWorldPos.y = heightAtWorldPos(pointWorldPos.xz);

	vec3 toRadarCenter = radarcenter_range.xyz - pointWorldPos.xyz;
	float dist_to_center = length(toRadarCenter);

	// Early discard outside in FS (cheaper alpha kill there) – we still compute ray for simplicity
	vec3 smallstep = toRadarCenter / resolution;
	float obscured = 0.0;
	for (float i = 0.0; i < resolution; i += 1.0 ) {
		vec3 raypos = pointWorldPos.xyz + smallstep * i;
		float heightatsample = heightAtWorldPos(raypos.xz);
		obscured = max(obscured, heightatsample - raypos.y);
		if (obscured >= 2.0) break; // sufficiently blocked
	}

	float visible = (obscured < 2.0 && dist_to_center <= radarcenter_range.w) ? 1.0 : 0.0;
	// Slight lift to avoid z-fighting with terrain
	pointWorldPos.y += 0.15;
	worldPos = pointWorldPos;
	centerposrange = vec4(radarMidPos, radarcenter_range.w);
	unobscured = visible;
	gl_Position = cameraViewProj * vec4(pointWorldPos.xyz, 1.0);
}
