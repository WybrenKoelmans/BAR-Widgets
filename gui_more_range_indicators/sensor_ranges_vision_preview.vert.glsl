#version 420
#line 10000

// This shader is (c) Beherith (mysterme@gmail.com), adapted for vision preview

//__DEFINES__

layout (location = 0) in vec2 xyworld_xyfract;
uniform vec4 visioncenter_range;  // x y z range
uniform float resolution;  // how many steps are done

uniform sampler2D heightmapTex;

out DataVS {
		vec4 worldPos;
		vec4 centerposrange;
		vec4 blendedcolor;
		float worldscale_circumference;
};

//__ENGINEUNIFORMBUFFERDEFS__

#line 11009

float heightAtWorldPos(vec2 w){
	vec2 uvhm =   vec2(clamp(w.x,8.0,mapSize.x-8.0),clamp(w.y,8.0, mapSize.y-8.0))/ mapSize.xy;
	return max(0.0, textureLod(heightmapTex, uvhm, 0.0).x);
}

void main() {
	// transform the point to the center of the visioncenter_range

	vec4 pointWorldPos = vec4(0.0);

	// Add LOS bonus height (16 units) to both positions - matches engine behavior
	vec3 visionSourcePos = visioncenter_range.xyz + vec3(0.0, 16.0, 0.0);
	pointWorldPos.xz = (visioncenter_range.xz +  (xyworld_xyfract.xy * visioncenter_range.w));
	pointWorldPos.y = heightAtWorldPos(pointWorldPos.xz) + 16.0; // Add LOS bonus height

	vec3 tovisioncenter = visionSourcePos - pointWorldPos.xyz;
	float dist_to_center = length(tovisioncenter.xz); // Use XZ distance for 2D calculations
	float totalDistance = length(tovisioncenter);

		// No per-vertex occlusion, do it in fragment shader for accuracy

		worldscale_circumference = 1.0;
		worldPos = vec4(pointWorldPos);
		blendedcolor = vec4(0.0);
		blendedcolor.a = 0.6; // Slightly more opaque than radar

		// Vision color - more blue-white tint, similar calculation to radar
			blendedcolor.b = 1.0;
			blendedcolor.g = 1.0;
			blendedcolor.r = 1.0;
			blendedcolor.a = 0.6;

		pointWorldPos.y += 0.1;
		worldPos = pointWorldPos;
		gl_Position = cameraViewProj * vec4(pointWorldPos.xyz, 1.0);
		centerposrange = vec4(visionSourcePos, visioncenter_range.w);
}
