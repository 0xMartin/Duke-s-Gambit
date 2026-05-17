shader_type spatial;
render_mode unshaded, blend_add;

#include "util/blend_util.gdshaderinc"

group_uniforms Color;
uniform vec3 primary_color : source_color = vec3(1.0);
uniform vec3 secondary_color : source_color = vec3(1.0, 0.8, 0.4);
uniform float emission = 2.0;
uniform float emission_mult = 1.0;

group_uniforms Shape;
uniform float streaks1_count = 5.0;
uniform float streaks2_count = 11.0;
uniform float streaks_fade : hint_range(-2.0, 2.0, 0.01) = 0.4;
uniform float streaks_thickness : hint_range(0.0, 4.0, 0.01) = 0.5;
uniform float center_radius : hint_range(0.0, 1.0, 0.01) = 0.1;
uniform float fade_radius : hint_range(0.0, 1.0, 0.01) = 0.4;

group_uniforms Alpha;
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
	}
}

void fragment() {
	vec2 centered_uv = UV - 0.5;
	float angle = (atan(centered_uv.x, centered_uv.y));
	float radius = length(centered_uv) * 2.0;
	
	float view_offset = (NORMAL.x) * 0.5 + 0.5;
	
	if(NORMAL.z > 0.0) {
		view_offset = 1.0 - view_offset;
	}
	
	view_offset *= TAU;
	
	float streaks1 = sin((angle) * streaks1_count + view_offset + TIME);
	float streaks2 = sin((angle) * streaks2_count - view_offset - TIME);
	
	float value = overlay(streaks1, streaks2);
	
	value -= (1.0 - radius) * streaks_fade;
	value *= 1.0 - (radius - value * streaks_thickness);
	
	float mask = max(1.0 - radius, 0.0);
	value *= mask;
	value = min(value, mask);
	
	value = smoothstep(0.1, 1.0, value);
	value *= pow(clamp((radius - center_radius) / (fade_radius - center_radius), 0.0, 1.0), 4.0);
	
	ALBEDO = mix(secondary_color, primary_color, value) * COLOR.rgb * emission * emission_mult;
	
	ALPHA = value * COLOR.a;
	
	// Proximity Fade
	if(proximity_fade){
		float proximity_depth_tex = textureLod(depth_texture, SCREEN_UV, 0.0).r;
		vec4 ndc = OUTPUT_IS_SRGB ? vec4(vec3(SCREEN_UV, proximity_depth_tex) * 2.0 - 1.0, 1.0) : vec4(SCREEN_UV * 2.0 - 1.0, proximity_depth_tex, 1.0);
		vec4 proximity_view_pos = INV_PROJECTION_MATRIX * ndc;
		proximity_view_pos.xyz /= proximity_view_pos.w;
		ALPHA *= clamp(1.0 - smoothstep(proximity_view_pos.z + proximity_fade_distance, proximity_view_pos.z, VERTEX.z), 0.0, 1.0);
	}
}

