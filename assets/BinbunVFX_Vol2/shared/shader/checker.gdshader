shader_type spatial;

group_uniforms Color;
uniform vec3 primary_color : source_color = vec3(0.12);
uniform vec3 secondary_color : source_color = vec3(0.05);

varying vec3 world_pos;

uniform sampler2D checker_texture;
uniform sampler2D roughness_texture;
uniform sampler2D normal_texture;

void vertex(){
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float checker = texture(checker_texture, world_pos.xz).r;
	
	vec3 color = mix(secondary_color, primary_color, checker);
	
	vec3 normal_map = texture(normal_texture, world_pos.xz).rgb;
	
	NORMAL_MAP = normal_map;
	
	float roughness = texture(roughness_texture, world_pos.xz * 0.2).r;
	ROUGHNESS = roughness;
	
	ALBEDO = color;
}
