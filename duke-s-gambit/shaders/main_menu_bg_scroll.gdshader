shader_type canvas_item;

uniform vec2 scroll_speed = vec2(-0.015, 0.0225);

void fragment() {
	float repeat_scale = min(
		TEXTURE_PIXEL_SIZE.x / SCREEN_PIXEL_SIZE.x,
		TEXTURE_PIXEL_SIZE.y / SCREEN_PIXEL_SIZE.y
	) * 0.5;
	vec2 tiled_uv = fract(UV * vec2(repeat_scale) + TIME * scroll_speed);
	COLOR = texture(TEXTURE, tiled_uv);
}
