// outline.gdshader
// Rim/fresnel glow applied as material_overlay on selected pieces.
// Uses additive blending so it glows at silhouette edges without replacing the base colour.
shader_type spatial;
render_mode unshaded, blend_add;

uniform float rim_power     : hint_range(0.1, 8.0) = 1.5;   // lower = wider rim band
uniform float rim_intensity : hint_range(0.0, 5.0) = 2.5;   // brightness multiplier
uniform float fill_glow     : hint_range(0.0, 1.0) = 0.12;  // constant ambient across whole piece
uniform vec4  outline_color : source_color          = vec4(1.0, 0.85, 0.0, 1.0);

void fragment() {
	float ndotv = abs(dot(NORMAL, VIEW));
	float rim   = pow(1.0 - ndotv, rim_power) * rim_intensity;
	float glow  = clamp(rim + fill_glow, 0.0, 1.0);
	ALBEDO = outline_color.rgb * glow;
	ALPHA  = glow;
}
