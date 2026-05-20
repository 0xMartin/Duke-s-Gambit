extends Node3D

@export var flag_color: Color = Color(0.95, 0.95, 0.95, 1.0)
@export var flag_size: Vector2 = Vector2(1.70, 1.00)
@export var logo_texture: Texture2D = preload("res://assets/textures/java_logo.png")

const FLAG_SHADER: Shader = preload("res://shaders/flag_wave.gdshader")

func _ready() -> void:
	if get_child_count() > 0:
		return
	_build_flag()

func _build_flag() -> void:
	var flag_mesh := MeshInstance3D.new()
	flag_mesh.name = "FlagCloth"
	var cloth := PlaneMesh.new()
	cloth.size = flag_size
	cloth.subdivide_width = 32
	cloth.subdivide_depth = 16
	flag_mesh.mesh = cloth
	flag_mesh.rotation_degrees = Vector3(0.0, 0.0, 0.0)
	flag_mesh.position = Vector3.ZERO
	var flag_mat := ShaderMaterial.new()
	flag_mat.shader = FLAG_SHADER
	flag_mat.set_shader_parameter("flag_color", flag_color)
	flag_mat.set_shader_parameter("logo_texture", logo_texture)
	flag_mat.set_shader_parameter("logo_strength", 1.0)
	flag_mat.set_shader_parameter("wave_strength", 0.20)
	flag_mat.set_shader_parameter("wave_frequency", 4.2)
	flag_mat.set_shader_parameter("sag_strength", 0.10)
	flag_mesh.material_override = flag_mat
	flag_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(flag_mesh)
