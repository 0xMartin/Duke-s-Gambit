// outline.gdshader
// Inverted-hull outline: expands back-faces along normals and culls front-faces,
// so only the silhouette ring is visible from any camera angle.
// Applied as material_overlay on selected pieces.
shader_type spatial;
render_mode unshaded, cull_front;

uniform float outline_width : hint_range(0.0, 0.2) = 0.5;
uniform vec4  outline_color : source_color          = vec4(1.0, 0.85, 0.0, 1.0);

void vertex() {
	// Push each vertex outward along its normal to form a slightly larger shell.
	// Because front-faces are culled, only the shell peeking past the silhouette is drawn.
	VERTEX += NORMAL * outline_width;
}

void fragment() {
	ALBEDO = outline_color.rgb;
	ALPHA  = outline_color.a;
}
