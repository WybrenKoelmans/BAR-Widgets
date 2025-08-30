#version 420
// Combined Allied Radar Coverage Fragment Shader – draws solid green where unobscured for this radar
// Overdraw across all radars forms union (no intensity build-up due to constant color & overwrite blending)

//__ENGINEUNIFORMBUFFERDEFS__

in DataVS {
	vec4 worldPos;
	vec4 centerposrange;
	float unobscured;
};

out vec4 fragColor;

void main() {
	if (unobscured < 0.5) discard; // let base red show through
	// Use same alpha as red base so union remains consistent & transparent
	fragColor = vec4(0.0, 1.0, 0.0, 0.49);
}
