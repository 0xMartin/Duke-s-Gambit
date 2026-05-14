shader_type spatial;
render_mode unshaded, blend_add;

#include "util/blend_util.gdshaderinc"

group_uniforms Color;
uniform vec3 primary_color : source_color = vec3(1.0);
uniform vec3 secondary_color : source_color = vec3(1.0, 0.8, 0.4);
uniform float emission = 4.0;
uniform float emission_mult = 1.0;

group_uniforms Shape;
uniform bool alpha_as_factor = false;
uniform float grow_factor : hint_range(0.0, 1.0, 0.01) = 0.5;
uniform float streak_count = 3.0;
uniform float streak_twist = 3.0;
uniform float streak_exponent : hint_range(0.5, 6.0, 0.01) = 2.0;
uniform float streak_scroll = 3.0;

uniform sampler2D noise_texture;
uniform float noise_scroll = 0.2;
uniform float noise_twist = 2.0;
uniform vec2 spiral_noise_scale = vec2(1.0);

group_uniforms Alpha;
uniform float edge_hardness : hint_range(0.0, 1.0, 0.01) = 0.0;
uniform float edge_position : hint_range(0.0, 1.0, 0.01) = 0.5;
uniform bool proximity_fade = false;
uniform float proximity_fade_distance : hint_range(0.0, 8.0, 0.1) = 0.5;

uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;
varying flat int id;

void vertex() {
	id = INSTANCE_ID;
}

void fragment() {
	vec2 centered_uv = UV * 2.0 - 1.0;
	float angle = (atan(centered_uv.x, centered_uv.y));
	float radius = clamp(length(centered_uv),0.0, 1.0);
	
	vec2 noise_uv = vec2((angle + radius * noise_twist) / TAU, radius - TIME * noise_scroll);
	float noise = texture(noise_texture, noise_uv * spiral_noise_scale).r;
	
	float spiral = abs(sin((angle * (streak_count * 0.5) + float(id)) + (radius * streak_twist) - TIME * streak_scroll));
	spiral = pow(spiral, streak_exponent);
	
	float factor = alpha_as_factor ? COLOR.a : grow_factor;
	
	float mask = 1.0 - spiral;
	mask = radius + mask * 0.05;
	mask = max(pow(1.0 - abs(mask * 2.0 - factor * 3.0), 1.0), 0.0) * (1.0 - mask);
	mask = clamp(pow(mask, 0.5), 0.0, 1.0);
	
	noise *= mask;
	
	noise *= spiral;
	noise = pow(noise, 4.0) * 10.0;
	
	float l_edge = mix(0.0, edge_position, edge_hardness);
	float r_edge = mix(1.0, edge_position + 0.01, edge_hardness);
	noise = smoothstep(l_edge,r_edge,noise);
	
	ALPHA = sqrt(noise) * COLOR.a;
	
	ALBEDO = mix(secondary_color, primary_color, noise) * COLOR.rgb * emission * emission_mult;
	
	// Proximity Fade
	if(proximity_fade){
		float proximity_depth_tex = textureLod(depth_texture, SCREEN_UV, 0.0).r;
		vec4 ndc = OUTPUT_IS_SRGB ? vec4(vec3(SCREEN_UV, proximity_depth_tex) * 2.0 - 1.0, 1.0) : vec4(SCREEN_UV * 2.0 - 1.0, proximity_depth_tex, 1.0);
		vec4 proximity_view_pos = INV_PROJECTION_MATRIX * ndc;
		proximity_view_pos.xyz /= proximity_view_pos.w;
		ALPHA *= clamp(1.0 - smoothstep(proximity_view_pos.z + proximity_fade_distance, proximity_view_pos.z, VERTEX.z), 0.0, 1.0);
	}
}

//void light() {
//	// Called for every pixel for every light affecting the material.
//	// Uncomment to replace the default light processing function with this one.
//}
