// Blob shadow — soft blurred circle drawn under each chess piece.
// Uses identical render_mode to tile_highlight so it composites correctly.
shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled;

uniform float opacity  : hint_range(0.0, 1.0) = 0.52;
uniform float softness : hint_range(0.0, 0.5) = 0.18;  // blur band at the edge only

void fragment() {
	vec2  uv   = UV - vec2(0.5);          // 0,0 = center, ±0.5 = edges
	float dist = length(uv);              // 0 at center, ~0.5 at edge of inscribed circle
	// Full opacity from center up to (0.5 - softness), then fades to transparent.
	float a = (1.0 - smoothstep(0.5 - softness, 0.5, dist)) * opacity;
	ALBEDO = vec3(0.0);
	ALPHA  = a;
}
