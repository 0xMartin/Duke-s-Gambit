shader_type spatial;
render_mode unshaded, blend_add;

group_uniforms Color;
uniform vec3 primary_color : source_color = vec3(1.0);
uniform vec3 secondary_color : source_color = vec3(1.0, 0.8, 0.4);
uniform float emission = 2.0;
uniform float emission_mult = 1.0;

void fragment() {
	float fresnel = clamp(pow(dot(NORMAL, VIEW), 8.0), 0.0, 1.0);
	
	ALBEDO = (mix(secondary_color, primary_color, fresnel) * COLOR.a) * emission * emission_mult;
	
	ALPHA = fresnel;
}