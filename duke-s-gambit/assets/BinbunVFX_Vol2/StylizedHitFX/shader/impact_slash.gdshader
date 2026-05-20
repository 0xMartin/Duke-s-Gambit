shader_type spatial;
render_mode unshaded;

group_uniforms Color;
uniform vec3 primary_color : source_color = vec3(1.0);
uniform vec3 secondary_color : source_color = vec3(1.0, 0.6, 0.2);
uniform float emission = 2.0;
uniform float emission_mult = 1.0;

group_uniforms Shape;
uniform float pinch_amount : hint_range(0.0, 1.0, 0.01) = 0.4;

group_uniforms Animation;
uniform bool alpha_as_factor = false;
uniform float animation_factor : hint_range(0.0, 1.0, 0.01) = 0.5;

group_uniforms Noise;
uniform sampler2D noise_texture;
uniform vec2 noise_scale = vec2(1.0, 0.4);

group_uniforms Alpha;
uniform float edge_hardness : hint_range(0.0, 1.0, 0.01) = 0.8;
uniform bool proximity_fade = false;
uniform float proximity_fade_distance : hint_range(0.0, 8.0, 0.1) = 0.5;

uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;

varying flat int id;

void vertex() {
	id = INSTANCE_ID;
}

void fragment() {
	float factor = alpha_as_factor ? COLOR.a : animation_factor;
	
	vec2 scaled_uv = (1.0 - UV - vec2(0.5, 0.0)) * vec2(2.0, 1.0);
	float r = length(scaled_uv);
	float gradient = pow(1.0 - UV.y, 0.5) * 2.0;
	r /= (1.0 - pinch_amount) + gradient * pinch_amount;
	
	float id_offset = float(id) / PI;
	
	vec2 noise_uv = (UV + vec2(0.0, factor * 1.0) + id_offset) * noise_scale;
	float noise = texture(noise_texture, noise_uv).r;
	
	float shape = (r - noise * 0.5) * 2.0;
	
	float wave_offset = (factor * 4.0) - 1.0;
	float value = 1.0 - abs(shape * 2.0 - wave_offset);
	float mask = clamp(1.0 - (shape * shape * shape), 0.0, 1.0) * gradient ;
	value *= mask;
	value *= pow(factor, 0.1);
	value *= min((UV.y) * 8.0, 1.0);
	
	float l_edge = mix(0.0, 0.2 - 0.01, edge_hardness);
	float r_edge = mix(1.0, 0.2, edge_hardness);
	value = smoothstep(l_edge,r_edge,value);
	
	ALBEDO = (mix(secondary_color, primary_color, value) * COLOR.rgb) * emission * emission_mult;
	ALPHA = value;
	
	if(proximity_fade){
		float proximity_depth_tex = textureLod(depth_texture, SCREEN_UV, 0.0).r;
		vec4 ndc = OUTPUT_IS_SRGB ? vec4(vec3(SCREEN_UV, proximity_depth_tex) * 2.0 - 1.0, 1.0) : vec4(SCREEN_UV * 2.0 - 1.0, proximity_depth_tex, 1.0);
		vec4 proximity_view_pos = INV_PROJECTION_MATRIX * ndc;
		proximity_view_pos.xyz /= proximity_view_pos.w;
		ALPHA *= clamp(1.0 - smoothstep(proximity_view_pos.z + proximity_fade_distance, proximity_view_pos.z, VERTEX.z), 0.0, 1.0);
	}
}