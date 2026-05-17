shader_type spatial;
render_mode unshaded, blend_add, cull_disabled;

group_uniforms Color;
uniform vec3 primary_color : source_color = vec3(1.0);
uniform vec3 secondary_color : source_color = vec3(1.0, 0.8, 0.4);
uniform float emission = 2.0;
uniform float emission_mult = 1.0;

group_uniforms Shape;
uniform bool alpha_as_factor = false;
uniform float animation_factor : hint_range(0.0, 1.0, 0.01) = 0.5;
uniform sampler2D noise_texture;
uniform vec2 scroll = vec2(0.2);

group_uniforms Alpha;
uniform float edge_hardness : hint_range(0.0, 1.0, 0.01) = 0.5;
uniform float edge_position : hint_range(0.0, 1.0, 0.01) = 0.5;

group_uniforms Displacement;
uniform float noise_displacement = 0.2;
uniform float displacement = 0.2;

float sample_noise(vec2 uv){
	float pole_mask = max(uv.y, 1.0 - uv.y) * 2.0 - 1.0;
	pole_mask = 1.0 - pow(pole_mask, 8.0);
	float noise = min(texture(noise_texture, uv + (scroll * TIME)).r, 1.0) * pole_mask;
	return noise;
}

void vertex() {
	float factor = alpha_as_factor ? COLOR.a : max(animation_factor, 0.0);
	VERTEX += (NORMAL * sample_noise(UV) * noise_displacement) * factor;
	VERTEX += NORMAL * displacement * factor;
}

void fragment() {
	float noise = sample_noise(UV);
	
	float factor = alpha_as_factor ? COLOR.a : max(animation_factor, 0.0);
	
	noise += (1.0 - factor) * 2.0 - 1.0;
	float value = clamp(noise, 0.0, 1.0);
	
	float l_edge = mix(0.0, edge_position, edge_hardness);
	float r_edge = mix(1.0, edge_position + 0.01, edge_hardness);
	value = smoothstep(l_edge,r_edge,value);
	
	
	ALPHA = value;
	PREMUL_ALPHA_FACTOR = value;
	
	vec3 color = mix(secondary_color, primary_color, value) * emission * emission_mult;
	
	if(!FRONT_FACING){
		color = secondary_color;
	}
	
	ALBEDO = color * emission;
}
