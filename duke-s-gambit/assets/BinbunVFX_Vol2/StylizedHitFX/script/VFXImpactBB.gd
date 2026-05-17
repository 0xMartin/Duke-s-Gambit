@tool
extends VFXControllerBB
class_name VFXImpactBB

var audio_stream_player : AudioStreamPlayer3D:
	get():
		if audio_stream_player:
			return audio_stream_player
		
		var result = get_node_or_null("AudioStreamPlayer3D")
		
		if !Engine.is_editor_hint():
			audio_stream_player = result
		
		return result

var light : VFXOmniLightBB:
	get():
		if light:
			return light
		
		var result = get_node_or_null("VFXOmniLightBB")
		
		if !Engine.is_editor_hint():
			light = result
		
		return result

var impact_sphere : GPUParticles3D:
	get():
		if impact_sphere:
			return impact_sphere
		
		var result = get_node_or_null("ImpactSphere")
		
		if !Engine.is_editor_hint():
			impact_sphere = result
		
		return result

var hit_core : GPUParticles3D:
	get():
		if hit_core:
			return hit_core
		
		var result = get_node_or_null("HitCore")
		
		if !Engine.is_editor_hint():
			hit_core = result
		
		return result

@export_group("Color")

## The most prominant color
@export var primary_color : Color:
	set(v):
		primary_color = v
		_set_shader_param("primary_color", primary_color)

## The color that effects fade into at edges
@export var secondary_color : Color:
	set(v):
		secondary_color = v
		_set_shader_param("secondary_color", secondary_color)

## Emission of the effect. Higher values give glowyness if glow is enabled in environment.
@export var emission : float = 1.0:
	set(v):
		emission = v
		_set_shader_param("emission_mult", emission)

@export_group("Light")

## Color of the emitted light
@export var light_color : Color:
	set(v):
		light_color = v
		if light:
			light.light_color = light_color

## Strength multiplier of the light.
@export var light_energy : float = 4.0:
	set(v):
		light_energy = v
		if light:
			light.vfx_light_energy = light_energy

## Secondary strength multiplier of the light used with indirect light.
@export var light_indirect_energy : float = 1.0:
	set(v):
		light_indirect_energy = v
		if light:
			light.vfx_indirect_energy = light_indirect_energy

## Secondary strength multiplier of the light used with volumetric fog.
@export var light_volumetric_fog_energy : float = 1.0:
	set(v):
		light_volumetric_fog_energy = v
		if light:
			light.vfx_volumetric_fog_energy = light_volumetric_fog_energy

@export_group("Shape")

## Changes the shape of the flashes flying off impacts
@export_range(0.0, 1.0, 0.01) var flash_pinch : float = 0.4:
	set(v):
		flash_pinch = v
		_set_shader_param("pinch_amount", flash_pinch)

## Changes the noise scale of the flashes flying off impacts
@export var flash_noise_scale : Vector2 = Vector2(0.8, 0.2):
	set(v):
		flash_noise_scale = v
		_set_shader_param("noise_scale", flash_noise_scale)

## On Impact effects hides the glowy ball in the middle. On hit effects hides the star.
@export var hide_core : bool = false:
	set(v):
		hide_core = v
		if impact_sphere: impact_sphere.visible = !hide_core
		if hit_core: hit_core.visible = !hide_core

@export_group("Transparency")

## Hardness of effects edges.
@export_range(0.0, 1.0, 0.01) var edge_hardness : float = 0.5:
	set(v):
		edge_hardness = v
		_set_shader_param("edge_hardness", edge_hardness)

## Fade effects close to other surfaces. Can affect performance, but prevents the effect from having hard clipping edges.
@export var proximity_fade : bool = false:
	set(v):
		proximity_fade = v
		_set_shader_param("proximity_fade", proximity_fade)

## Distance of the proximity fade. Does nothing if proximity_fade is not enabled
@export_range(0.0, 8.0, 0.01) var proximity_fade_distance : float = 1.0:
	set(v):
		proximity_fade_distance = v
		_set_shader_param("proximity_fade_distance", proximity_fade_distance)

@export_group("Audio")

## Audio stream used for the effect. Other audio related settings are the same as with AudioStreamPlayer3D
@export var audio_stream : AudioStream:
	set(v):
		audio_stream = v
		if audio_stream_player: audio_stream_player.stream = audio_stream

@export var attenuation_model : AudioStreamPlayer3D.AttenuationModel:
	set(v):
		attenuation_model = v
		if audio_stream_player: audio_stream_player.attenuation_model = attenuation_model

@export_range(-80.0, 80.0, 0.01, "suffix:dB") var volume_db : float = 0.0:
	set(v):
		volume_db = v
		if audio_stream_player: audio_stream_player.volume_db

@export_range(0.1, 100.0, 0.01) var unit_size : float = 10.0:
	set(v):
		unit_size = v
		if audio_stream_player: audio_stream_player.unit_size = unit_size

@export_range(-24.0, 6.0, 0.01, "suffix:dB") var max_db : float = 3.0:
	set(v):
		max_db = v
		if audio_stream_player: audio_stream_player.max_db = max_db

@export_range(0.01, 4.0, 0.01) var pitch_scale : float = 1.0:
	set(v):
		pitch_scale = v
		if audio_stream_player: audio_stream_player.pitch_scale = pitch_scale

@export var stream_paused : bool = false:
	set(v):
		stream_paused = v
		if audio_stream_player: audio_stream_player.stream_paused = stream_paused

@export_range(0.0, 2000.0, 0.01, "suffix:m") var audio_max_distance : float = 3.0:
	set(v):
		audio_max_distance = v
		if audio_stream_player: audio_stream_player.max_distance = audio_max_distance

@export var max_polyphony : int = 1:
	set(v):
		max_polyphony = v
		if audio_stream_player: audio_stream_player.max_polyphony = max_polyphony

@export_range(0.0, 3.0, 0.01) var panning_strength : float = 1.0:
	set(v):
		panning_strength = v
		if audio_stream_player: audio_stream_player.panning_strength = panning_strength

@export var bus : StringName = &"Master":
	set(v):
		bus = v
		if audio_stream_player: audio_stream_player.bus = bus

@export_group("About")

@export_tool_button("Documentation", "ExternalLink") var docs_button : Callable:
	get():
		return func(): OS.shell_open("https://bun3d.com/assets/vfx/godot_hit_fx/#usage")
