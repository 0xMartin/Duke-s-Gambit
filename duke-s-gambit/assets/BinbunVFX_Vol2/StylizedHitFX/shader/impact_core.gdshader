shader_type spatial;
render_mode unshaded;

group_uniforms Color;
uniform vec3 primary_color : source_color = vec3(1.0);
uniform vec3 secondary_color : source_color = vec3(1.0, 0.8, 0.4);
uniform float emission = 2.0;
uniform float emission_mult = 1.0;

group_uniforms Shape;
uniform bool alpha_as_factor = false;
uniform float grow_factor : hint_range(0.0, 1.0, 0.01) = 0.5;
uniform float streak_amount = 7.0;
uniform float clearance = 0.0;
uniform float variance_amplitude = 10.0;
uniform float variance_strength : hint_range(0.0, 1.0, 0.01) = 0.1;

group_uniforms Alpha;
uniform float edge_hardness : hint_range(0.0, 1.0, 0.01) = 0.5;
uniform float edge_position : hint_range(0.0, 1.0, 0.01) = 0.5;
uniform bool proximity_fade = false;
uniform float proximity_fade_distance : hint_range(0.0, 8.0, 0.1) = 0.5;

uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;

group_uniforms Billboard;
uniform bool billboard = false;

void vertex() {
	if(billboard){
		MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
				MAIN_CAM_INV_VIEW_MATRIX[0],
				MAIN_CAM_INV_VIEW_MATRIX[1],
				MAIN_CAM_INV_VIEW_MATRIX[2],
				MODEL_MATRIX[3]);
		MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
	}
}

void fragment() {
	vec2 centered_uv = UV * 2.0 - 1.0;
	float radius = length(centered_uv);
	float angle = atan(centered_uv.x, centered_uv.y);
	
	float factor = alpha_as_factor ? COLOR.a : grow_factor;
	factor = factor * 4.0 - 1.0;
	
	float offset = (abs(sin(angle * (streak_amount * 0.5) + TIME)) * radius) + clearance;
	offset += (sin(angle * variance_amplitude) * radius) * variance_strength;
	radius += offset * 0.5;
	float value = 1.0 - abs((radius * 2.0 - factor));
	value *= max(pow(1.0 - radius, 0.1), 0);
	
	float l_edge = mix(0.0, edge_position, edge_hardness);
	float r_edge = mix(1.0, edge_position + 0.01, edge_hardness);
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
