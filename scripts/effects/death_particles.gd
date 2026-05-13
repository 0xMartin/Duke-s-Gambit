## death_particles.gd
## Attached to a GPUParticles3D node in scenes/effects/death_particles.tscn
## Uses assets/textures/fog.png as the particle texture, tinted to a chosen colour.

extends GPUParticles3D

## Tint of the fog/smoke particles (easily changed)
@export var particle_color: Color = Color(0.6, 0.4, 1.0, 0.9)   # purple-ish soul smoke

func _ready() -> void:
	# Build process material at runtime so we don't need a saved .tres
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape          = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius  = 0.6
	pm.direction               = Vector3(0, 1, 0)
	pm.spread                  = 60.0
	pm.gravity                 = Vector3(0, -0.5, 0)
	pm.initial_velocity_min    = 0.8
	pm.initial_velocity_max    = 2.0
	pm.angular_velocity_min    = -90.0
	pm.angular_velocity_max    =  90.0
	pm.scale_min               = 0.8
	pm.scale_max               = 2.4
	pm.color                   = particle_color
	# Fade out over lifetime
	var grad := Gradient.new()
	grad.add_point(0.0, Color(particle_color.r, particle_color.g, particle_color.b, 1.0))
	grad.add_point(1.0, Color(particle_color.r, particle_color.g, particle_color.b, 0.0))
	var grad_tex := GradientTexture1D.new()
	grad_tex.gradient = grad
	pm.color_ramp = grad_tex
	process_material = pm

	# Build draw mesh + material using fog.png
	var fog_tex: Texture2D = load("res://assets/textures/fog.png")
	var draw_mat := StandardMaterial3D.new()
	draw_mat.transparency         = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
	draw_mat.albedo_texture       = fog_tex
	draw_mat.albedo_color         = particle_color
	draw_mat.billboard_mode       = BaseMaterial3D.BILLBOARD_ENABLED
	draw_mat.shading_mode         = BaseMaterial3D.SHADING_MODE_UNSHADED
	draw_mat.render_priority      = 2
	draw_mat.texture_filter       = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	var quad := QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)
	quad.surface_set_material(0, draw_mat)
	draw_pass_1 = quad
	draw_passes  = 1

	amount   = 40
	lifetime = 1.2
	one_shot = true
	emitting = true
