shader_type canvas_item;

uniform float float_amplitude = 10.0;
uniform float float_speed = 2.4;

void vertex() {
	VERTEX.y += sin(TIME * float_speed) * float_amplitude;
}
