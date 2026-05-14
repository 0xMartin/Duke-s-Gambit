shader_type spatial;
render_mode unshaded, blend_add;

group_uniforms Color;
uniform vec3 primary_color : source_color = vec3(1.0);
uniform vec3 secondary_color : source_color = vec3(1.0, 0.8, 0.4);
uniform float emission = 2.0;
uniform float emission_mult = 1.0;

uniform float star_shape : hint_range(0.1, 2.0, 0.01) = 2.0;
uniform float star_smoothness : hint_range(0.0, 1.0, 0.1) = 0.1;

group_uniforms Alpha;
uniform bool proximity_fade = false;
uniform float proximity_fade_distance : hint_range(0.0, 8.0, 0.1) = 0.5;

uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;

void vertex() {
	// Called for every vertex the material is visible on.
}

void fragment() {
	vec2 uv = abs(UV * 2.0 - 1.0);
	
	
	float decay = COLOR.a * 1.0;
	float value = clamp(pow(uv.x, star_shape * decay) + pow(uv.y, star_shape * decay), 0.0, 2.0);
	
	value = smoothstep(0.95, 0.95 - star_smoothness, value);
	
	vec3 color = mix(secondary_color, primary_color, value);
	
	ALBEDO = color * COLOR.rgb * emission * emission_mult;
	
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

//void light() {
//	// Called for every pixel for every light affecting the material.
//	// Uncomment to replace the default light processing function with this one.
//}
