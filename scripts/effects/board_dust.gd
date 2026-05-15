extends GPUParticles3D

@export var dust_color: Color = Color(0.88, 0.84, 0.76, 0.32)

func _ready() -> void:
	local_coords = false
	visibility_aabb = AABB(Vector3(-5.0, -0.2, -5.0), Vector3(10.0, 0.8, 10.0))

	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(4.4, 0.03, 4.4)
	pm.direction = Vector3(0.0, 1.0, 0.0)
	pm.spread = 180.0
	pm.gravity = Vector3(0.0, 0.01, 0.0)
	pm.initial_velocity_min = 0.01
	pm.initial_velocity_max = 0.08
	pm.damping_min = 0.1
	pm.damping_max = 0.35
	pm.angular_velocity_min = -18.0
	pm.angular_velocity_max = 18.0
	pm.scale_min = 0.03
	pm.scale_max = 0.10
	pm.color = dust_color

	var grad := Gradient.new()
	grad.add_point(0.0, Color(dust_color.r, dust_color.g, dust_color.b, 0.0))
	grad.add_point(0.15, Color(dust_color.r, dust_color.g, dust_color.b, dust_color.a))
	grad.add_point(1.0, Color(dust_color.r, dust_color.g, dust_color.b, 0.0))
	var grad_tex := GradientTexture1D.new()
	grad_tex.gradient = grad
	pm.color_ramp = grad_tex
	process_material = pm

	var draw_mat := StandardMaterial3D.new()
	draw_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
	draw_mat.albedo_texture = load("res://assets/textures/fog.png")
	draw_mat.albedo_color = dust_color
	draw_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	draw_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	draw_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	draw_mat.render_priority = 1
	var quad := QuadMesh.new()
	quad.size = Vector2(0.14, 0.14)
	quad.surface_set_material(0, draw_mat)
	draw_pass_1 = quad
	draw_passes = 1

	amount = 80
	lifetime = 8.0
	one_shot = false
	preprocess = 2.0
	explosiveness = 0.0
	emitting = true
