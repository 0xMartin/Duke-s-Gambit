shader_type spatial;
render_mode cull_disabled, blend_mix;

uniform vec4 flag_color : source_color = vec4(0.95, 0.95, 0.95, 1.0);
uniform sampler2D logo_texture;
uniform float logo_strength : hint_range(0.0, 1.0) = 1.0;
uniform vec2 logo_size = vec2(0.58, 0.34);
uniform float wave_strength : hint_range(0.0, 0.5) = 0.06;
uniform float wave_speed : hint_range(0.0, 8.0) = 1.8;
uniform float wave_frequency : hint_range(0.0, 12.0) = 4.0;
uniform float anchor_width : hint_range(0.0, 0.5) = 0.16;

void vertex() {
	float along = UV.x;
	float anchor = smoothstep(0.0, anchor_width, along);
	float flutter = sin(TIME * wave_speed + along * wave_frequency) * wave_strength * anchor;
	float ripple = sin(TIME * wave_speed * 1.7 + UV.y * 8.0 + along * 2.5) * wave_strength * 0.45 * anchor;
	float billow = sin(TIME * wave_speed * 0.6 + UV.y * 4.0) * wave_strength * 0.25 * anchor;
	VERTEX.y += flutter + ripple;
	VERTEX.x += billow * 0.35;
	VERTEX.z += ripple * 0.2;
}

void fragment() {
	float shade = 0.88 + 0.12 * (1.0 - UV.x);
	vec3 base_color = flag_color.rgb * shade;
	vec2 logo_half = logo_size * 0.5;
	vec2 local = UV - vec2(0.5);
	vec2 logo_uv = local / logo_size + vec2(0.5);
	if (!FRONT_FACING) {
		logo_uv.x = 1.0 - logo_uv.x;
	}
	float inside = step(abs(local.x), logo_half.x) * step(abs(local.y), logo_half.y);
	vec4 logo = texture(logo_texture, logo_uv);
	vec3 final_color = mix(base_color, logo.rgb, logo.a * logo_strength * inside);
	ALBEDO = final_color;
	ALPHA = flag_color.a;
}
