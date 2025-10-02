#version 420
// This shader is (c) Beherith (mysterme@gmail.com), adapted for vision preview

#line 20000

uniform vec4 visioncenter_range;  // x y z range
uniform float resolution;  // how many steps are done

uniform sampler2D heightmapTex;

//__ENGINEUNIFORMBUFFERDEFS__

//__DEFINES__
in DataVS {
		vec4 worldPos;
		vec4 centerposrange;
		vec4 blendedcolor;
		float worldscale_circumference;
};

out vec4 fragColor;

void main() {
			fragColor.rgba = blendedcolor.rgba;

			// Per-pixel occlusion check
			vec3 visionSourcePos = centerposrange.xyz;
			vec3 pointPos = worldPos.xyz;
			float dist_to_center = length(visionSourcePos.xz - pointPos.xz);
			float totalDistance = length(visionSourcePos - pointPos);
			float obscured = 0.0;
			if (dist_to_center > 1.0) {
				vec2 dir = normalize(pointPos.xz - visionSourcePos.xz);
				float stepSize = max(8.0, dist_to_center / resolution);
				for (float d = stepSize; d < dist_to_center; d += stepSize) {
					vec2 samplePos = visionSourcePos.xz + dir * d;
					vec2 uvhm = vec2(clamp(samplePos.x,8.0,mapSize.x-8.0),clamp(samplePos.y,8.0,mapSize.y-8.0))/ mapSize.xy;
					float terrainHeight = max(0.0, textureLod(heightmapTex, uvhm, 0.0).x);
					float t = d / dist_to_center;
					float rayHeight = mix(visionSourcePos.y, pointPos.y, t);
					float heightDiff = terrainHeight - rayHeight;
					if (heightDiff > 8.0) {
						obscured = 1.0;
						break;
					}
				}
			}
			if (obscured > 0.5) {
				fragColor.a = 0.0;
				return;
			}

			vec2 toedge = centerposrange.xz - worldPos.xz;

			float angle = atan(toedge.y/toedge.x);

			angle = (angle + 1.56)/3.14;

			float angletime = fract(angle - timeInfo.x* 0.025); // Slower animation for vision

			angletime = 0.6; // Slightly brighter base for vision

			angle = clamp(angletime, 0.3, 0.9); // Wider range for vision

			vec2 mymin = min(worldPos.xz,mapSize.xy - worldPos.xz);
			float inboundsness = min(mymin.x, mymin.y);
			fragColor.a = min(smoothstep(0,1,fragColor.a), 1.0 - clamp(inboundsness*(-0.1),0.0,1.0));

			if (length(worldPos.xz - visioncenter_range.xz) > visioncenter_range.w) fragColor.a = 0.0;

			fragColor.a = fragColor.a * angle * 0.2; // 50% less alpha for more transparency

			// Vision-specific pulse effect - more subtle and blue-tinted
			float pulse = 1 + sin(-1.5 * sqrt(length(toedge)) + 0.025 * timeInfo.x);
			pulse *= pulse;
			fragColor.a = mix(fragColor.a, fragColor.a * pulse, 0.08); // More subtle pulse

			// Add a blue tint to distinguish from radar
			fragColor.rgb = mix(fragColor.rgb, vec3(0.7, 0.9, 1.0), 0.3);
}
