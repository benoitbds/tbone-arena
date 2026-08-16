extends Camera3D

## Caméra de poursuite arrière : suivi souple, recul + élargissement du FOV sous
## Nitro, et screenshake proportionnel aux impacts (système de "trauma").

@export var target: Node3D = null
@export var follow_speed: float = 9.0
@export var aim_speed: float = 14.0

@export var height: float = 3.4
@export var distance_behind: float = 8.2
@export var boost_extra_distance: float = 2.6
## Recul supplémentaire sous forte accélération. Piloté par la VARIATION de
## vitesse et non par la commande de gaz : un bot pied au plancher garde
## throttle = 1.0 en permanence, ce qui figerait la caméra en retrait.
@export var accel_recoil: float = 2.4
@export var accel_reference: float = 22.0    # m/s² donnant le recul maximal
@export var boost_extra_height: float = 0.5
@export var look_ahead: float = 4.0

@export var fov_base: float = 75.0
@export var fov_boost: float = 92.0
@export var fov_speed_gain: float = 0.35     # degrés par m/s au-delà de max_speed

@export var trauma_decay: float = 1.8
@export var max_offset_pos: float = 0.85     # mètres
@export var max_offset_rot: float = 4.5      # degrés

var boosting: bool = false
var trauma: float = 0.0

var _aim_point: Vector3 = Vector3.ZERO
var _boost_blend: float = 0.0
var _recoil: float = 0.0
var _prev_speed: float = 0.0
var _initialised: bool = false


func _ready() -> void:
	# La caméra vit dans l'espace monde : elle ne doit hériter ni de la rotation
	# ni de l'échelle du véhicule, sinon le drift la fait pivoter violemment.
	top_level = true
	fov = fov_base


func _process(delta: float) -> void:
	if not target or not is_instance_valid(target):
		return

	_boost_blend = move_toward(_boost_blend, 1.0 if boosting else 0.0, delta * 3.0)

	var car_basis: Basis = target.global_transform.basis
	var car_position: Vector3 = target.global_position

	var planar_speed: float = 0.0
	if target is CharacterBody3D:
		var velocity: Vector3 = (target as CharacterBody3D).velocity
		planar_speed = Vector3(velocity.x, 0.0, velocity.z).length()

	# --- Recul élastique : poussée ressentie à la remise des gaz ---
	# Mis à jour AVANT le calcul de la position visée, sinon le recul appliqué
	# serait celui de la frame précédente.
	var accel: float = 0.0
	if delta > 0.0:
		accel = (planar_speed - _prev_speed) / delta
	_prev_speed = planar_speed
	var target_recoil: float = clampf(accel / accel_reference, 0.0, 1.0) * accel_recoil
	# Recul vif, retour souple : c'est l'asymétrie qui donne le coup de reins.
	var rate: float = 6.0 if target_recoil > _recoil else 2.2
	_recoil = clampf(lerpf(_recoil, target_recoil, clampf(delta * rate, 0.0, 1.0)),
		0.0, accel_recoil)

	var back: float = distance_behind + boost_extra_distance * _boost_blend + _recoil
	var up: float = height + boost_extra_height * _boost_blend
	# +Z est l'arrière du véhicule.
	var desired: Vector3 = car_position + car_basis.z * back + Vector3.UP * up

	if not _initialised:
		_initialised = true
		global_position = desired
		_aim_point = car_position

	global_position = global_position.lerp(desired, clampf(follow_speed * delta, 0.0, 1.0))

	# Point de visée légèrement devant le capot pour ouvrir le champ en vitesse.
	var desired_aim: Vector3 = car_position - car_basis.z * look_ahead + Vector3.UP * 1.1
	_aim_point = _aim_point.lerp(desired_aim, clampf(aim_speed * delta, 0.0, 1.0))
	look_at(_aim_point, Vector3.UP)

	var target_fov: float = lerpf(fov_base, fov_boost, _boost_blend)
	target_fov += maxf(0.0, planar_speed - 32.0) * fov_speed_gain
	fov = lerpf(fov, target_fov, clampf(delta * 5.0, 0.0, 1.0))

	if trauma > 0.0:
		trauma = maxf(0.0, trauma - trauma_decay * delta)
		_apply_shake()


func add_trauma(amount: float) -> void:
	trauma = clampf(trauma + amount, 0.0, 1.0)


func _apply_shake() -> void:
	# Trauma quadratique : les petits chocs restent discrets, les gros claquent.
	var shake: float = trauma * trauma
	global_position += Vector3(
		randf_range(-1.0, 1.0),
		randf_range(-1.0, 1.0),
		randf_range(-1.0, 1.0)
	) * max_offset_pos * shake
	rotation_degrees += Vector3(
		randf_range(-1.0, 1.0),
		randf_range(-1.0, 1.0),
		randf_range(-1.0, 1.0)
	) * max_offset_rot * shake
