shader_type spatial;
render_mode unshaded, blend_add, cull_disabled;

#include "util/blend_util.gdshaderinc"

group_uniforms Color;
uniform vec3 primary_color : source_color = vec3(1.0);
uniform vec3 secondary_color : source_color = vec3(1.0, 0.8, 0.4);
uniform float emission = 2.0;
uniform float emission_mult = 1.0;

group_uniforms Shape;
uniform bool alpha_as_factor = false;
uniform float grow_factor : hint_range(0.0, 1.0, 0.01) = 0.5;
uniform sampler2D flare_texture;
uniform float streaks_amount = 4.0;
uniform float variance1_amplitude = 12.0;
uniform float variance2_amplitude = 5.0;

group_uniforms Alpha;
uniform float edge_hardness : hint_range(0.0, 1.0, 0.01) = 0.5;
uniform float edge_position : hint_range(0.0, 1.0, 0.01) = 0.1;
uniform bool proximity_fade = false;
uniform float proximity_fade_distance = 1.0;

uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;


group_uniforms Billboard;
uniform bool billboard = false;

varying flat int id;

void vertex() {
	id = INSTANCE_ID;
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
	float flare = texture(flare_texture, UV).r;
	flare = pow(flare, 8.0) * 0.8;
	
	vec2 centered_uv = UV - 0.5;
	float angle = (atan(centered_uv.x, centered_uv.y));
	
	float id_offset = float(id);
	
	float streaks = pow(cos((angle + id_offset) * streaks_amount) * 0.5 + 0.5, 16.0);
	float variance1 = sin((angle + id_offset) * variance1_amplitude) * 0.5 + 0.5;
	streaks *= variance1;
	
	float value = overlay(flare, streaks);
	value = max(value, flare*0.5);
	
	float variance2 = sin((angle + id_offset) * variance2_amplitude + id_offset) * 0.5 + 0.5;
	value *= (0.5 + variance2 * 0.5);
	
	float l_edge = mix(0.0, edge_position, edge_hardness);
	float r_edge = mix(1.0, edge_position + 0.01, edge_hardness);
	value = smoothstep(l_edge,r_edge,value);
	
	ALBEDO = (mix(secondary_color, primary_color, value) * COLOR.rgb) * emission * COLOR.a * emission_mult;
	
	ALPHA = value;
	
	// Proximity Fade
	if(proximity_fade){
		float proximity_depth_tex = textureLod(depth_texture, SCREEN_UV, 0.0).r;
		vec4 ndc = OUTPUT_IS_SRGB ? vec4(vec3(SCREEN_UV, proximity_depth_tex) * 2.0 - 1.0, 1.0) : vec4(SCREEN_UV * 2.0 - 1.0, proximity_depth_tex, 1.0);
		vec4 proximity_view_pos = INV_PROJECTION_MATRIX * ndc;
		proximity_view_pos.xyz /= proximity_view_pos.w;
		ALPHA *= clamp(1.0 - smoothstep(proximity_view_pos.z + proximity_fade_distance, proximity_view_pos.z, VERTEX.z), 0.0, 1.0);
	}
}
