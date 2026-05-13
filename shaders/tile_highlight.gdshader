// tile_highlight.gdshader
// Draws a full-opacity border + semi-transparent fill on a board square overlay.
// Visible on both white and dark tiles regardless of fill colour.
shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled;

uniform vec4  tile_color   : source_color        = vec4(0.2, 0.85, 0.3, 0.85);
uniform float border_width : hint_range(0.0, 0.5) = 0.09;
uniform float fill_alpha   : hint_range(0.0, 1.0) = 0.35;

void fragment() {
	float bw = border_width;
	bool on_border = UV.x < bw || UV.x > 1.0 - bw
	              || UV.y < bw || UV.y > 1.0 - bw;
	float a = on_border ? tile_color.a : tile_color.a * fill_alpha;
	ALBEDO = tile_color.rgb;
	ALPHA  = a;
}
