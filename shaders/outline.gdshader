// outline.gdshader
// Rim/fresnel glow applied as material_overlay on selected pieces.
// Uses additive blending so it glows at silhouette edges without replacing the base colour.
shader_type spatial;
render_mode unshaded, blend_add;

uniform float rim_power    : hint_range(0.5, 10.0) = 2.2;
uniform vec4  outline_color : source_color          = vec4(1.0, 0.82, 0.0, 1.0);

void fragment() {
	float rim = 1.0 - abs(dot(NORMAL, VIEW));
	rim = pow(rim, rim_power);
	ALBEDO = outline_color.rgb * rim;
	ALPHA  = rim * outline_color.a;
}
