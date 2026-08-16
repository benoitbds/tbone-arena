class_name Car
extends CharacterBody3D

## Stock-car arcade, autoritatif serveur.
##
## Répartition des responsabilités :
##  - SERVEUR  : échantillonne les entrées reçues, intègre la physique, résout
##               les impacts (T-Bone), applique les dégâts et le respawn.
##  - CLIENTS  : n'exécutent QUE l'échantillonnage clavier de leur propre voiture
##               et la cosmétique (mesh, particules, gomme, caméra, HUD).
##               Position / rotation / vélocité arrivent par MultiplayerSynchronizer.
##
## Aucune référence directe aux autoloads (NetworkManager / SoundManager) n'est
## faite ici : ce script est preloadé par network_manager.gd, barrel.gd et
## bot_client_runner.gd, et une dépendance croisée casserait la compilation.
## `class_name Car` ne sert plus qu'aux auto-références internes du script.

# Types résolus par preload et NON par le cache de classes globales
# (.godot/global_script_class_cache.cfg) : sur un clone neuf ou une image
# Docker fraîche, ce cache n'existe pas encore et `class_name` reste
# introuvable au chargement, ce qui faisait échouer tout le projet.
const CarVisuals = preload("res://scripts/cars/car_visuals.gd")

const SKIDMARK_SCENE: PackedScene = preload("res://scenes/fx/skidmark.tscn")
const SPARKS_SCENE: PackedScene = preload("res://scenes/fx/sparks_impact.tscn")
const DEBRIS_SCENE: PackedScene = preload("res://scenes/fx/debris_burst.tscn")

# --- Propulsion (strictement en m/s, aucune division parasite) ---
@export var max_speed: float = 32.0          # ~115 km/h
@export var nitro_speed: float = 52.0        # ~185 km/h
@export var reverse_speed: float = 15.0
@export var accel_rate: float = 40.0         # m/s²
@export var brake_rate: float = 72.0
@export var engine_brake: float = 12.0

# --- Direction ---
@export var turn_speed: float = 2.9          # rad/s
@export var turn_speed_drift: float = 4.3

# --- Adhérence latérale ---
@export var grip_normal: float = 58.0        # m/s² d'annulation de dérive
@export var grip_drift: float = 7.0
@export var grip_stunned: float = 15.0

# --- Nitro thermique ---
@export var heat_gain: float = 35.0          # %/s en poussée
@export var heat_cool: float = 20.0          # %/s au repos
@export var overheat_reset: float = 45.0     # seuil de sortie de surchauffe
@export var overheat_speed_malus: float = 0.62

# --- Intégrité ---
@export var max_health: float = 100.0
@export var respawn_delay: float = 3.5

# --- Résolution d'impact : bandes de vitesse relative projetée (m/s) ---
## En dessous : simple frottement de carrosserie, aucun dégât structurel.
const CONTACT_TOLERANCE: float = 4.0     # ~15 km/h
## Au-dessus : impact lourd (déformation, gibbing, projection violente).
const HEAVY_IMPACT: float = 14.0
## Seuil de bruit : en dessous, les corps se séparent, rien à résoudre.
const CONTACT_EPSILON: float = 0.5
const LIGHT_DAMAGE_PER_MS: float = 2.5   # dégâts = (v_rel - 4) * 2.5
const HEAVY_DAMAGE_PER_MS: float = 2.2
const MAX_SINGLE_HIT: float = 140.0

# --- Transfert de quantité de mouvement ---
const MOMENTUM_RETAINED: float = 0.35    # l'attaquant décélère de v_rel * 0.35
const MOMENTUM_TRANSFER: float = 0.85    # la cible encaisse v_rel * 0.85
# --- Moment angulaire sur impact décentré ---
const TORQUE_SCALE: float = 0.16
const MAX_SPIN: float = 4.2              # rad/s
const SPIN_DECAY: float = 3.4            # rad/s²

const MIN_IMPACT_SPEED: float = 6.0
const IMPACT_COOLDOWN: float = 0.25
const TBONE_MIN_ANGLE: float = 70.0
const TBONE_MAX_ANGLE: float = 110.0
const TBONE_MULT: float = 2.5
const DAMAGE_PER_MS: float = 1.15
const ATTACKER_BACKLASH: float = 0.22
const RAM_INERTIA_KEEP: float = 0.88          # le bélier ne s'arrête pas net
const WALL_RESTITUTION: float = 0.55
const PROP_IMPULSE: float = 26.0
const GRAVITY: float = 26.0

# --- Filet de sécurité physique ---
const MAX_LAUNCH_SOURCE: float = 34.0
const LAUNCH_SPEED_CAP: float = 1.15
const TERMINAL_FALL: float = 45.0
const SPEED_CAP_FACTOR: float = 1.25
# Limites de repli si la scène courante n'expose pas get_world_bounds().
const FALLBACK_BOUNDS: AABB = AABB(Vector3(-44.0, -4.0, -44.0), Vector3(88.0, 12.0, 88.0))

# --- État répliqué (cf. SceneReplicationConfig de car.tscn) ---
var owner_peer_id: int = 0                    # 0 = bot piloté par le serveur
var color_index: int = 0
var current_health: float = 100.0
var is_dead: bool = false

# --- Entrées (autoritatives côté serveur) ---
var input_throttle: float = 0.0
var input_steering: float = 0.0
var input_nitro: bool = false
var input_handbrake: bool = false

# --- État moteur ---
var heat: float = 0.0
var is_overheated: bool = false
var impact_stun: float = 0.0

# --- Course (renseigné par race_manager.gd) ---
var race_mode: bool = false
var controls_locked: bool = false
var race_lap: int = 1
var race_rank: int = 0
var race_total: int = 0
var race_wrong_way: bool = false
var race_finished: bool = false

# --- IA ---
var bot_stuck_timer: float = 0.0
var bot_reverse_timer: float = 0.0
var bot_escape_steer: float = 0.85
## Rythme propre à chaque bot (0.86 à 1.00). Avec un peloton parfaitement
## homogène, les 4 bots franchissaient le carrefour en X groupés sur la MÊME
## branche : jamais de T-Bone. Un écart de rythme les répartit sur le tracé et
## recrée les croisements leader / retardataire voulus par le mode.
var bot_skill: float = 1.0

## Rotation induite par un impact décentré (rad/s). CharacterBody3D n'a pas de
## vitesse angulaire : on l'intègre à la main via rotate_y().
var spin_rate: float = 0.0

var _headless: bool = false
var _visuals: CarVisuals = null
var _camera: Camera3D = null
var _hud: CanvasLayer = null
var _local_view_ready: bool = false
var _built_color_index: int = -1
var _applied_stage: int = -1
var _respawn_timer: float = 0.0
var _skid_cooldown: float = 0.0
var _impact_cooldowns: Dictionary = {}
# Vélocité d'avant move_and_slide(), conservée pour que l'autre véhicule d'une
# paire en collision puisse raisonner sur l'élan RÉEL du bélier et pas sur une
# vélocité déjà rabotée par sa propre résolution de glissement.
var _pre_move_velocity: Vector3 = Vector3.ZERO
var _cached_bounds: AABB = FALLBACK_BOUNDS
var _bounds_resolved: bool = false
# Navigation sur circuit : abscisse curviligne suivie de façon MONOTONE.
# Une recherche du point le plus proche referait basculer le bot sur l'autre
# branche au carrefour en X (les deux s'y superposent) et l'enverrait à
# contresens. On n'avance donc que vers l'avant, dans une fenêtre bornée.
var _path_offset: float = -1.0
var _offtrack_timer: float = 0.0
var _last_sent_input: Array = []
var _drift_smoke: Array[CPUParticles3D] = []
var _nitro_flames: Array[CPUParticles3D] = []
var _engine_smoke: CPUParticles3D = null
# --- Audio par véhicule (client uniquement) ---
var _engine_player: AudioStreamPlayer3D = null
var _tire_player: AudioStreamPlayer3D = null
var _prev_nitro: bool = false
var _backfire_cooldown: float = 0.0
var _engine_fire: CPUParticles3D = null


func _ready() -> void:
	_headless = DisplayServer.get_name() == "headless"
	_visuals = $Body as CarVisuals
	_drift_smoke = [$DriftSmokeL as CPUParticles3D, $DriftSmokeR as CPUParticles3D]
	_nitro_flames = [$NitroFlameL as CPUParticles3D, $NitroFlameR as CPUParticles3D]
	_engine_smoke = $EngineSmoke as CPUParticles3D
	_engine_fire = $EngineFire as CPUParticles3D

	if multiplayer.is_server():
		current_health = max_health
		# Échelonné sur l'index de spawn (séquentiel), et non sur un hash : un
		# hash regroupait les quatre bots sur des valeurs voisines et le peloton
		# restait compact. Des paliers francs garantissent leaders ET retardataires.
		bot_skill = 1.0 - 0.06 * float(color_index % 4)

	# Sur un serveur headless, aucun mesh n'est bâti : la physique n'en a pas besoin.
	# Sur un serveur headless, ni mesh ni audio : le serveur dédié ne doit pas
	# synthétiser de son pour personne.
	if not _headless:
		_refresh_visual_color()
		_refresh_damage_stage(true)
		_setup_audio()


func _physics_process(delta: float) -> void:
	_bind_local_view()

	if multiplayer.is_server():
		_server_step(delta)
	else:
		_sample_local_input()

	if not _headless:
		_cosmetic_step(delta)


# ---------------------------------------------------------------------------
# ENTRÉES
# ---------------------------------------------------------------------------

func is_local_player() -> bool:
	return owner_peer_id != 0 and owner_peer_id == multiplayer.get_unique_id()


func is_bot() -> bool:
	return owner_peer_id == 0


func _sample_local_input() -> void:
	if not is_local_player():
		return

	var throttle: float = 0.0
	var steering: float = 0.0
	var nitro: bool = false
	var handbrake: bool = false

	if not is_dead:
		throttle = Input.get_axis("ui_down", "ui_up")
		steering = Input.get_axis("ui_right", "ui_left")
		nitro = Input.is_key_pressed(KEY_SPACE)
		handbrake = Input.is_key_pressed(KEY_SHIFT)

	if multiplayer.is_server():
		# Hôte local / entraînement solo : pas de aller-retour réseau.
		_store_inputs(throttle, steering, nitro, handbrake)
		return

	# N'émettre que sur changement réel pour ne pas saturer le canal.
	var packed: Array = [throttle, steering, nitro, handbrake]
	if packed != _last_sent_input:
		_last_sent_input = packed
		update_inputs.rpc_id(1, throttle, steering, nitro, handbrake)


@rpc("any_peer", "call_local", "unreliable_ordered")
func update_inputs(throttle: float, steering: float, nitro: bool, handbrake: bool) -> void:
	if not multiplayer.is_server():
		return
	# 0 => appel local (OfflineMultiplayerPeer / call_local), 1 => serveur.
	var sender: int = multiplayer.get_remote_sender_id()
	if sender != 0 and sender != 1 and sender != owner_peer_id:
		return
	_store_inputs(throttle, steering, nitro, handbrake)


func _store_inputs(throttle: float, steering: float, nitro: bool, handbrake: bool) -> void:
	if controls_locked:
		input_throttle = 0.0
		input_steering = 0.0
		input_nitro = false
		input_handbrake = false
		return
	input_throttle = clampf(throttle, -1.0, 1.0)
	input_steering = clampf(steering, -1.0, 1.0)
	input_nitro = nitro
	input_handbrake = handbrake


# ---------------------------------------------------------------------------
# SIMULATION SERVEUR
# ---------------------------------------------------------------------------

func _server_step(delta: float) -> void:
	_tick_impact_cooldowns(delta)

	if is_dead:
		_respawn_timer -= delta
		velocity = velocity.move_toward(Vector3.ZERO, 40.0 * delta)
		if _respawn_timer <= 0.0:
			_respawn()
		return

	if is_bot():
		if race_mode:
			run_bot_race_ai(delta)
		else:
			_run_bot_ai(delta)
	else:
		_sample_local_input()

	if controls_locked:
		_store_inputs(0.0, 0.0, false, false)
		velocity = velocity.move_toward(Vector3.ZERO, 60.0 * delta)

	_update_heat(delta)

	if impact_stun > 0.0:
		impact_stun = maxf(0.0, impact_stun - delta)

	# --- Chasse du train arrière consécutive à un impact décentré ---
	if absf(spin_rate) > 0.001:
		rotate_y(spin_rate * delta)
		spin_rate = move_toward(spin_rate, 0.0, SPIN_DECAY * delta)

	var forward: Vector3 = -global_transform.basis.z
	var right: Vector3 = global_transform.basis.x
	var fwd_speed: float = velocity.dot(forward)

	# --- Braquage : direct, inversé en marche arrière ---
	if absf(input_steering) > 0.01:
		var direction_sign: float = 1.0 if absf(fwd_speed) < 1.0 else signf(fwd_speed)
		var rate: float = turn_speed_drift if input_handbrake else turn_speed
		# L'autorité de direction chute pendant l'encaissement d'un choc.
		if impact_stun > 0.0:
			rate *= 0.35
		# Braquage plein à basse vitesse, légèrement adouci en pointe.
		var speed_factor: float = clampf(absf(fwd_speed) / 8.0, 0.25, 1.0)
		speed_factor = lerpf(speed_factor, 0.72, clampf((absf(fwd_speed) - 26.0) / 26.0, 0.0, 1.0))
		rotate_y(input_steering * rate * speed_factor * direction_sign * delta)
		forward = -global_transform.basis.z
		right = global_transform.basis.x

	# --- Accélération longitudinale ---
	var boosting: bool = input_nitro and not is_overheated
	var top_speed: float = nitro_speed if boosting else max_speed
	if is_overheated:
		top_speed *= overheat_speed_malus

	var target_fwd: float = 0.0
	if input_throttle > 0.01:
		target_fwd = input_throttle * top_speed
	elif input_throttle < -0.01:
		target_fwd = input_throttle * reverse_speed

	var rate_long: float = accel_rate
	if absf(input_throttle) < 0.01:
		rate_long = engine_brake
	elif signf(input_throttle) != signf(fwd_speed) and absf(fwd_speed) > 1.0:
		rate_long = brake_rate
	var new_fwd: float = move_toward(fwd_speed, target_fwd, rate_long * delta)

	# --- Adhérence latérale / découplage de traction en drift ---
	var lat_speed: float = velocity.dot(right)
	var grip: float = grip_normal
	if impact_stun > 0.0:
		grip = grip_stunned
	elif input_handbrake:
		grip = grip_drift
	var new_lat: float = move_toward(lat_speed, 0.0, grip * delta)

	var planar: Vector3 = forward * new_fwd + right * new_lat
	velocity.x = planar.x
	velocity.z = planar.z

	if is_on_floor():
		velocity.y = 0.0
	else:
		velocity.y = maxf(velocity.y - GRAVITY * delta, -TERMINAL_FALL)

	var pre_velocity: Vector3 = velocity
	_pre_move_velocity = pre_velocity
	move_and_slide()
	_resolve_impacts(pre_velocity)
	_enforce_safety_bounds()


## Filet de sécurité physique : aucun véhicule ne peut être catapulté hors de
## l'arène, dépasser une vitesse absurde ou basculer sur le flanc.
func _enforce_safety_bounds() -> void:
	var planar: Vector3 = Vector3(velocity.x, 0.0, velocity.z)
	var speed_cap: float = nitro_speed * SPEED_CAP_FACTOR
	if planar.length() > speed_cap:
		planar = planar.normalized() * speed_cap
		velocity.x = planar.x
		velocity.z = planar.z
	velocity.y = clampf(velocity.y, -TERMINAL_FALL, 10.0)

	# Le véhicule ne pivote que sur Y : toute inclinaison vient d'une sortie de
	# pénétration et doit être annulée immédiatement.
	if absf(rotation.x) > 0.0001 or absf(rotation.z) > 0.0001:
		rotation = Vector3(0.0, rotation.y, 0.0)

	if not _world_bounds().has_point(global_position):
		print("[SAFETY] ", name, " hors limites en ", global_position, " : réinsertion.")
		_respawn()


## Volume de jeu du niveau courant (arène 80×80 ou circuit 140×80).
func _world_bounds() -> AABB:
	if _bounds_resolved:
		return _cached_bounds
	var level: Node = get_tree().current_scene
	if level and level.has_method("get_world_bounds"):
		_cached_bounds = level.call("get_world_bounds") as AABB
	else:
		_cached_bounds = FALLBACK_BOUNDS
	_bounds_resolved = true
	return _cached_bounds


func _update_heat(delta: float) -> void:
	if input_nitro and not is_overheated:
		heat = minf(100.0, heat + heat_gain * delta)
		if heat >= 100.0:
			is_overheated = true
	else:
		heat = maxf(0.0, heat - heat_cool * delta)
		# Verrou de surchauffe : il faut vraiment redescendre pour relancer.
		if is_overheated and heat <= overheat_reset:
			is_overheated = false


# ---------------------------------------------------------------------------
# COLLISIONS / TRANSFERT D'ÉNERGIE
# ---------------------------------------------------------------------------

func _tick_impact_cooldowns(delta: float) -> void:
	if _impact_cooldowns.is_empty():
		return
	for key: int in _impact_cooldowns.keys():
		var remaining: float = float(_impact_cooldowns[key]) - delta
		if remaining <= 0.0:
			_impact_cooldowns.erase(key)
		else:
			_impact_cooldowns[key] = remaining


func _resolve_impacts(pre_velocity: Vector3) -> void:
	for i: int in get_slide_collision_count():
		var collision: KinematicCollision3D = get_slide_collision(i)
		var collider: Object = collision.get_collider()
		var normal: Vector3 = collision.get_normal()
		normal.y = 0.0
		if normal.length_squared() < 0.001:
			continue
		normal = normal.normalized()

		if collider is Car:
			_resolve_car_impact(collider as Car, normal, pre_velocity, collision.get_position())
		elif collider is RigidBody3D:
			# CharacterBody3D ne pousse pas les corps rigides : impulsion manuelle,
			# sans quoi baril et piles de pneus se comportent comme des murs.
			var rb: RigidBody3D = collider as RigidBody3D
			var rb_key: int = rb.get_instance_id()
			if _impact_cooldowns.has(rb_key):
				continue
			var push: float = maxf(0.0, pre_velocity.dot(-normal))
			if push > 2.0:
				_impact_cooldowns[rb_key] = IMPACT_COOLDOWN
				# Impulsion CENTRALE et bornée : un bras de levier sur un cylindre
				# léger produisait une vitesse angulaire démente, et la sortie de
				# pénétration du CharacterBody3D catapultait le véhicule hors de
				# l'arène. Sans couple, le prop est poussé, jamais mis en orbite.
				rb.apply_central_impulse(-normal * minf(push, 30.0) * PROP_IMPULSE)
				# Le baril explosif ne peut pas détecter un corps cinématique
				# lui-même : c'est au véhicule de déclarer le choc.
				if rb.has_method("try_detonate"):
					rb.call("try_detonate", (pre_velocity - rb.linear_velocity).length())
		else:
			# Glissière de sécurité : rebond élastique explicite.
			# move_and_slide() ignore physics_material_override, on réfléchit à la main.
			var closing: float = pre_velocity.dot(normal)
			if closing < -3.0:
				velocity = pre_velocity.bounce(normal) * WALL_RESTITUTION
				velocity.y = 0.0
				_broadcast_impact(collision.get_position(), absf(closing) * 0.02)


## Résolution d'un contact entre deux véhicules.
##
## Tout découle d'UNE grandeur : la vitesse relative PROJETÉE sur la normale.
## `collision.get_normal()` fuit le collider (il pointe vers nous), donc un
## rapprochement donne un produit scalaire négatif : on raisonne sur `push_dir`
## (de nous vers la cible) pour obtenir une magnitude positive en approche.
##
##   v_rel <  4 m/s : frottement de carrosserie, 0 dégât, micro-étincelles
##   4..14 m/s      : dégâts proportionnels (v_rel - 4) * 2.5
##   v_rel >= 14    : impact lourd, gibbing, projection violente
func _resolve_car_impact(other: Car, normal: Vector3, pre_velocity: Vector3,
		contact_point: Vector3) -> void:
	if is_dead or other.is_dead:
		return
	var key: int = other.get_instance_id()
	if _impact_cooldowns.has(key):
		return

	var other_velocity: Vector3 = other._pre_move_velocity
	var push_dir: Vector3 = -normal            # de nous vers la cible
	var v_rel: float = (pre_velocity - other_velocity).dot(push_dir)
	if v_rel < CONTACT_EPSILON:
		return                                  # les corps se séparent

	_impact_cooldowns[key] = IMPACT_COOLDOWN
	other._impact_cooldowns[get_instance_id()] = IMPACT_COOLDOWN

	# --- Qui percute qui : le plus engagé dans l'axe de choc est l'attaquant ---
	var my_drive: float = pre_velocity.normalized().dot(push_dir) if pre_velocity.length() > 0.1 else -1.0
	var their_drive: float = other_velocity.normalized().dot(normal) if other_velocity.length() > 0.1 else -1.0
	var attacker: Car = self
	var victim: Car = other
	var hit_dir: Vector3 = push_dir
	if their_drive > my_drive:
		attacker = other
		victim = self
		hit_dir = normal

	# --- T-Bone : angle des caps ET contact sur le FLANC de la cible ---
	var heading_dot: float = clampf(
		(-attacker.global_transform.basis.z).dot(-victim.global_transform.basis.z), -1.0, 1.0)
	var angle: float = rad_to_deg(acos(heading_dot))
	var flank_hit: float = absf(hit_dir.dot(victim.global_transform.basis.x))
	var is_tbone: bool = angle >= TBONE_MIN_ANGLE and angle <= TBONE_MAX_ANGLE and flank_hit > 0.6

	# --- Dégâts par bande de vitesse ---
	var damage: float = 0.0
	var severity: int = 0
	if v_rel >= HEAVY_IMPACT:
		severity = 2
		damage = (HEAVY_IMPACT - CONTACT_TOLERANCE) * LIGHT_DAMAGE_PER_MS \
			+ (v_rel - HEAVY_IMPACT) * HEAVY_DAMAGE_PER_MS
		# Le ×2.5 T-Bone ne s'applique QUE dans la bande critique : l'appliquer
		# à la bande 4-14 doublerait la formule (v_rel-4)*2.5 déjà spécifiée.
		if is_tbone:
			damage *= TBONE_MULT
	elif v_rel >= CONTACT_TOLERANCE:
		severity = 1
		damage = (v_rel - CONTACT_TOLERANCE) * LIGHT_DAMAGE_PER_MS
	# else : severity 0, damage 0 -> simple contact de carrosserie.
	damage = minf(damage, MAX_SINGLE_HIT)

	if damage > 0.0:
		victim.apply_damage(damage, attacker.display_name(), is_tbone)
		# Contrecoup attribué à la victime : killfeed cohérent si le bélier meurt.
		attacker.apply_damage(damage * ATTACKER_BACKLASH, victim.display_name(), false)

	# --- Transfert de quantité de mouvement le long de la normale ---
	# L'attaquant repart de sa vélocité d'AVANT move_and_slide() : la résolution
	# reste non bloquante, il n'est jamais stoppé net par le contact.
	var source: float = minf(v_rel, MAX_LAUNCH_SOURCE)
	velocity = pre_velocity - push_dir * (source * MOMENTUM_RETAINED)
	velocity.y = minf(velocity.y, 0.0)
	other.velocity = other_velocity + push_dir * (source * MOMENTUM_TRANSFER)
	other.velocity.y = 0.0

	# Plafonds conservés du correctif précédent : sans eux, des chocs successifs
	# cumulaient leur élan et collaient les véhicules au plafond de sécurité.
	_clamp_planar(self)
	_clamp_planar(other)

	# --- Moment angulaire : un impact décentré fait chasser le train arrière ---
	var lever: Vector3 = contact_point - victim.global_position
	lever.y = 0.0
	var torque: float = lever.cross(hit_dir * source).y
	victim.spin_rate = clampf(victim.spin_rate + torque * TORQUE_SCALE, -MAX_SPIN, MAX_SPIN)

	if severity > 0:
		victim.impact_stun = 0.65 if severity == 2 else 0.3

	_broadcast_impact(contact_point, [0.05, 0.18, 0.35][severity], severity)
	if is_tbone and severity == 2:
		victim.notify_tbone.rpc()


func _clamp_planar(car: Car) -> void:
	var planar: Vector3 = Vector3(car.velocity.x, 0.0, car.velocity.z)
	var cap: float = car.nitro_speed * LAUNCH_SPEED_CAP
	if planar.length() > cap:
		planar = planar.normalized() * cap
		car.velocity.x = planar.x
		car.velocity.z = planar.z


func display_name() -> String:
	if is_bot():
		return name
	return "Pilote " + str(owner_peer_id)


# ---------------------------------------------------------------------------
# DÉGÂTS / MORT / RESPAWN
# ---------------------------------------------------------------------------

## Applique des dégâts (serveur uniquement) puis pousse le nouvel état aux pairs.
func apply_damage(amount: float, source: String, is_tbone: bool) -> void:
	if not multiplayer.is_server() or is_dead or amount <= 0.0:
		return

	current_health = maxf(0.0, current_health - amount)
	if current_health <= 0.0:
		is_dead = true
		_respawn_timer = respawn_delay
		input_throttle = 0.0
		input_steering = 0.0
		input_nitro = false
		_announce("💥 " + display_name() + " détruit par " + source + ("  [T-BONE]" if is_tbone else ""))

	sync_health.rpc(current_health, is_dead)


## Alias historique conservé pour les appels externes (barrel.gd, outils, tests).
func take_damage(amount: float, source: String, is_tbone: bool) -> void:
	apply_damage(amount, source, is_tbone)


## Pousse l'intégrité autoritative vers tous les pairs (et localement).
@rpc("authority", "call_local", "reliable")
func sync_health(new_health: float, dead: bool) -> void:
	var was_dead: bool = is_dead
	current_health = new_health
	is_dead = dead

	if _headless:
		return

	_refresh_damage_stage(false)
	if is_dead and not was_dead:
		_spawn_debris()
	elif was_dead and not is_dead:
		_reset_visuals()

	if is_local_player() and _hud:
		_hud.call("update_health", current_health, max_health)


@rpc("authority", "call_local", "reliable")
func notify_tbone() -> void:
	if _headless or not is_local_player() or not _hud:
		return
	_hud.call("show_tbone_critical")


func _respawn() -> void:
	is_dead = false
	current_health = max_health
	heat = 0.0
	is_overheated = false
	impact_stun = 0.0
	velocity = Vector3.ZERO
	spin_rate = 0.0
	bot_stuck_timer = 0.0
	bot_reverse_timer = 0.0
	# Le véhicule vient d'être téléporté : le suivi monotone de l'abscisse ne
	# peut pas le retrouver dans sa fenêtre avant, il faut réacquérir.
	_path_offset = -1.0
	_offtrack_timer = 0.0

	# Point de réinsertion fourni par le niveau : radial en arène, retour sur la
	# ligne idéale (tangente à la courbe) en circuit.
	var level: Node = get_tree().current_scene
	var recovery: Transform3D
	if level and level.has_method("get_recovery_transform"):
		recovery = level.call("get_recovery_transform", global_position) as Transform3D
	else:
		var angle: float = randf() * TAU
		var origin: Vector3 = Vector3(cos(angle) * 24.0, 0.6, sin(angle) * 24.0)
		recovery = Transform3D(Basis(Vector3.UP, atan2(origin.x, origin.z)), origin)
	global_position = recovery.origin
	global_rotation = Vector3(0.0, recovery.basis.get_euler().y, 0.0)
	sync_health.rpc(current_health, is_dead)


func _announce(message: String) -> void:
	var arena: Node = get_tree().current_scene
	if arena and arena.has_method("broadcast_killfeed"):
		arena.call("broadcast_killfeed", message)
	else:
		print("[KILLFEED] ", message)


# ---------------------------------------------------------------------------
# IA DE COMBAT (serveur uniquement)
# ---------------------------------------------------------------------------

func _run_bot_ai(delta: float) -> void:
	var planar_speed: float = Vector3(velocity.x, 0.0, velocity.z).length()

	# Routine anti-blocage : marche arrière braquée.
	if bot_reverse_timer > 0.0:
		bot_reverse_timer -= delta
		_store_inputs(-1.0, bot_escape_steer, false, false)
		return

	if planar_speed < 2.0 and absf(input_throttle) > 0.1:
		bot_stuck_timer += delta
		if bot_stuck_timer > 1.2:
			bot_stuck_timer = 0.0
			bot_reverse_timer = 1.4
			# Sens de dégagement tiré au sort : un braquage constant refaisait
			# ramer le bot dans le même obstacle en boucle.
			bot_escape_steer = 0.85 if randf() < 0.5 else -0.85
			_store_inputs(-1.0, bot_escape_steer, false, false)
			return
	else:
		bot_stuck_timer = maxf(0.0, bot_stuck_timer - delta)

	# Traque du véhicule vivant le plus proche.
	var target: Car = null
	var best_distance: float = INF
	var siblings: Node = get_parent()
	if siblings:
		for child: Node in siblings.get_children():
			if child == self or not (child is Car):
				continue
			var other: Car = child as Car
			if other.is_dead:
				continue
			var distance: float = global_position.distance_to(other.global_position)
			if distance < best_distance:
				best_distance = distance
				target = other

	if not target:
		# Aucune cible : regagner le centre de l'arène pour recréer du contact.
		var to_center: Vector3 = -global_position
		to_center.y = 0.0
		_store_inputs(0.7, _steer_toward(to_center), false, false)
		return

	# Interception : viser légèrement devant la cible pour cadrer un flanc.
	var lead: Vector3 = target.global_position + target.velocity * 0.35
	var to_target: Vector3 = lead - global_position
	to_target.y = 0.0

	var forward: Vector3 = -global_transform.basis.z
	var direction: Vector3 = to_target.normalized()
	var alignment: float = forward.dot(direction)
	var steering: float = _steer_toward(to_target)

	var throttle: float = 1.0
	if alignment < -0.35 and best_distance < 8.0:
		# Cible dans le dos et trop proche pour tourner : reculer en braquant.
		throttle = -0.8
		steering = -steering

	# Nitro tactique : uniquement aligné, en ligne droite et avec de la marge.
	var use_nitro: bool = alignment > 0.9 and best_distance > 12.0 and not is_overheated and heat < 70.0
	# Frein à main pour recadrer un virage serré sur une cible latérale.
	var use_handbrake: bool = alignment < 0.35 and alignment > -0.35 and best_distance < 16.0

	_store_inputs(throttle, steering, use_nitro, use_handbrake)


# ---------------------------------------------------------------------------
# IA DE COURSE (serveur uniquement)
# ---------------------------------------------------------------------------

## Vitesse de passage visée selon la courbure à venir (m/s).
const RACE_APEX_SPEED: float = 17.0
const RACE_STRAIGHT_SPEED: float = 32.0
const RACE_LOOKAHEAD: float = 13.0      # distance de visée sur la ligne idéale
const RACE_CURVE_PROBE: float = 26.0    # distance d'anticipation du virage
const RACE_OFFTRACK_LIMIT: float = 11.0 # écart à la ligne idéale toléré
const RACE_SEARCH_WINDOW: float = 26.0  # fenêtre de recherche vers l'avant


func run_bot_race_ai(delta: float) -> void:
	var curve: Curve3D = _racing_curve()
	if not curve:
		# Pas de tracé exploitable : on retombe sur l'IA de derby.
		_run_bot_ai(delta)
		return

	var planar_speed: float = Vector3(velocity.x, 0.0, velocity.z).length()

	# --- Dégagement en marche arrière (bloqué contre un rail / hors trajectoire) ---
	if bot_reverse_timer > 0.0:
		bot_reverse_timer -= delta
		_store_inputs(-1.0, bot_escape_steer, false, false)
		return

	var offset: float = _advance_path_offset(curve)
	var line_point: Vector3 = curve.sample_baked(offset)
	var off_track: float = Vector3(
		global_position.x - line_point.x, 0.0, global_position.z - line_point.z).length()

	var blocked: bool = planar_speed < 2.5 and absf(input_throttle) > 0.1
	if blocked or off_track > RACE_OFFTRACK_LIMIT:
		_offtrack_timer += delta
		if _offtrack_timer > 1.5:
			_offtrack_timer = 0.0
			bot_reverse_timer = 1.2
			# Se dégager EN DIRECTION du centre de piste, pas au hasard.
			var to_line: Vector3 = line_point - global_position
			to_line.y = 0.0
			bot_escape_steer = -signf(_steer_toward(to_line))
			if absf(bot_escape_steer) < 0.1:
				bot_escape_steer = 0.85
			_store_inputs(-1.0, bot_escape_steer, false, false)
			return
	else:
		_offtrack_timer = maxf(0.0, _offtrack_timer - delta)

	var length: float = curve.get_baked_length()

	# --- Point de visée en avant sur la ligne idéale ---
	var aim: Vector3 = curve.sample_baked(fposmod(offset + RACE_LOOKAHEAD, length))
	var to_aim: Vector3 = aim - global_position
	to_aim.y = 0.0
	var steering: float = _steer_toward(to_aim)

	# --- Vitesse adaptative : freiner à l'approche d'un virage serré ---
	var here_dir: Vector3 = _curve_direction(curve, offset)
	var ahead_dir: Vector3 = _curve_direction(curve, fposmod(offset + RACE_CURVE_PROBE, length))
	var bend: float = here_dir.angle_to(ahead_dir)          # 0 = ligne droite
	var straightness: float = clampf(1.0 - bend / 1.1, 0.0, 1.0)
	var target_speed: float = lerpf(RACE_APEX_SPEED, RACE_STRAIGHT_SPEED, straightness) * bot_skill

	var throttle: float = 1.0
	if planar_speed > target_speed * 1.12:
		throttle = -0.55                                     # freinage d'appui
	elif planar_speed > target_speed:
		throttle = 0.25

	# Nitro en sortie de courbe et en ligne droite franche uniquement.
	var use_nitro: bool = straightness > 0.86 \
		and not is_overheated and heat < 72.0 \
		and absf(steering) < 0.35 \
		and off_track < 6.0

	# --- Agressivité en peloton : garder l'élan pour le bélier / T-Bone ---
	var rival: Car = _nearest_rival(16.0)
	if rival:
		var to_rival: Vector3 = rival.global_position - global_position
		to_rival.y = 0.0
		var heading: Vector3 = -global_transform.basis.z
		var side_dot: float = absf(to_rival.normalized().dot(global_transform.basis.x))
		# Adversaire sur le flanc, ou juste devant : on ne lève pas le pied.
		# On ne détourne la trajectoire que si l'adversaire est vraiment sur le
		# flanc ET qu'on reste sur la ligne : sinon les 5 concurrents passaient
		# leur course à se percuter sur place au lieu de tourner.
		if to_rival.length() < 9.0 and side_dot > 0.7 and off_track < 5.0:
			throttle = 1.0
			steering = clampf(steering + _steer_toward(to_rival) * 0.3, -1.0, 1.0)

	_store_inputs(throttle, steering, use_nitro, false)


## Suivi MONOTONE de l'abscisse curviligne : on ne cherche le point le plus
## proche que dans une fenêtre située DEVANT la position précédente. C'est ce
## qui empêche le bot de sauter sur l'autre branche au croisement en X.
func _advance_path_offset(curve: Curve3D) -> float:
	var length: float = curve.get_baked_length()

	if _path_offset < 0.0:
		# Première acquisition : recherche globale, le véhicule est sur la grille.
		var best: float = 0.0
		var best_distance: float = INF
		var steps: int = 200
		for i: int in steps:
			var candidate: float = float(i) / float(steps) * length
			var distance: float = curve.sample_baked(candidate).distance_squared_to(global_position)
			if distance < best_distance:
				best_distance = distance
				best = candidate
		_path_offset = best
		return _path_offset

	var search_best: float = _path_offset
	var search_distance: float = INF
	var samples: int = 26
	for i: int in samples:
		var candidate: float = _path_offset + float(i) / float(samples) * RACE_SEARCH_WINDOW
		var distance: float = curve.sample_baked(fposmod(candidate, length)).distance_squared_to(global_position)
		if distance < search_distance:
			search_distance = distance
			search_best = candidate
	_path_offset = fposmod(search_best, length)
	return _path_offset


func _curve_direction(curve: Curve3D, offset: float) -> Vector3:
	var length: float = curve.get_baked_length()
	var here: Vector3 = curve.sample_baked(fposmod(offset, length))
	var ahead: Vector3 = curve.sample_baked(fposmod(offset + 2.0, length))
	var direction: Vector3 = ahead - here
	direction.y = 0.0
	if direction.length_squared() < 0.0001:
		return -global_transform.basis.z
	return direction.normalized()


func _racing_curve() -> Curve3D:
	var level: Node = get_tree().current_scene
	if not level:
		return null
	var path: Path3D = level.get_node_or_null("RacingLine") as Path3D
	return path.curve if path else null


func _nearest_rival(max_distance: float) -> Car:
	var best: Car = null
	var best_distance: float = max_distance
	var siblings: Node = get_parent()
	if not siblings:
		return null
	for child: Node in siblings.get_children():
		if child == self or not (child is Car):
			continue
		var other: Car = child as Car
		if other.is_dead:
			continue
		var distance: float = global_position.distance_to(other.global_position)
		if distance < best_distance:
			best_distance = distance
			best = other
	return best


func _steer_toward(to_target: Vector3) -> float:
	if to_target.length_squared() < 0.01:
		return 0.0
	var direction: Vector3 = to_target.normalized()
	var forward: Vector3 = -global_transform.basis.z
	# forward × direction donne y > 0 quand la cible est à GAUCHE, et rotate_y()
	# positif fait tourner à gauche : le braquage suit donc directement cross.y.
	# (L'ancien code renvoyait -cross.y : les bots braquaient à l'opposé de leur
	# cible et finissaient collés aux glissières.)
	var cross_y: float = forward.cross(direction).y
	return clampf(cross_y * 3.0, -1.0, 1.0)


# ---------------------------------------------------------------------------
# AUDIO (clients uniquement)
# ---------------------------------------------------------------------------

## Vitesse maximale de chaque rapport (m/s). Le régime remonte à zéro à chaque
## passage : c'est ce qui produit à l'oreille les montées en régime et les
## rétrogradages, au lieu d'un pitch qui glisse linéairement avec la vitesse.
const GEAR_TOP_SPEED: Array[float] = [11.0, 21.0, 33.0, 55.0]
const ENGINE_PITCH_IDLE: float = 0.62
const ENGINE_PITCH_REDLINE: float = 2.35


func _setup_audio() -> void:
	var sound: Node = get_node_or_null("/root/SoundManager")
	if not sound or not sound.has_method("is_active") or not sound.call("is_active"):
		return
	_engine_player = sound.call("make_loop_player", self,
		sound.get("engine_stream"), -14.0, 90.0) as AudioStreamPlayer3D
	_tire_player = sound.call("make_loop_player", self,
		sound.get("tire_stream"), -60.0, 55.0) as AudioStreamPlayer3D


## Régime moteur (pitch) pour une vitesse donnée, via la boîte 4 rapports.
func _engine_pitch(speed: float) -> float:
	var last: int = GEAR_TOP_SPEED.size() - 1
	var gear: int = last
	var gear_bottom: float = GEAR_TOP_SPEED[last - 1]
	for i: int in GEAR_TOP_SPEED.size():
		if speed <= GEAR_TOP_SPEED[i]:
			gear = i
			gear_bottom = GEAR_TOP_SPEED[i - 1] if i > 0 else 0.0
			break
	var span: float = maxf(GEAR_TOP_SPEED[gear] - gear_bottom, 0.001)
	var rpm: float = clampf((speed - gear_bottom) / span, 0.0, 1.0)
	return lerpf(ENGINE_PITCH_IDLE, ENGINE_PITCH_REDLINE, rpm)


func _update_audio(delta: float, planar_speed: float, lateral_speed: float,
		fwd_speed: float) -> void:
	_backfire_cooldown = maxf(0.0, _backfire_cooldown - delta)

	if _engine_player:
		var target_pitch: float = _engine_pitch(planar_speed) + absf(input_throttle) * 0.12
		# Lissage : sans lui chaque changement de rapport claquerait.
		_engine_player.pitch_scale = lerpf(_engine_player.pitch_scale, target_pitch,
			clampf(delta * 7.0, 0.0, 1.0))
		var load_db: float = -60.0 if is_dead else lerpf(-19.0, -8.0, absf(input_throttle))
		_engine_player.volume_db = lerpf(_engine_player.volume_db, load_db,
			clampf(delta * 5.0, 0.0, 1.0))

	if _tire_player:
		# Le crissement suit le VECTEUR DE GLISSE latéral, pas la vitesse.
		var slip: float = clampf((absf(lateral_speed) - 3.0) / 14.0, 0.0, 1.0)
		if is_dead or planar_speed < 3.0:
			slip = 0.0
		_tire_player.volume_db = lerpf(_tire_player.volume_db,
			lerpf(-60.0, -6.0, slip), clampf(delta * 9.0, 0.0, 1.0))
		_tire_player.pitch_scale = lerpf(0.8, 1.45, slip)

	# --- Détonations d'échappement ---
	var sound: Node = get_node_or_null("/root/SoundManager")
	if not sound or not sound.has_method("play_backfire") or _backfire_cooldown > 0.0:
		_prev_nitro = input_nitro
		return
	var cut_nitro: bool = _prev_nitro and not input_nitro and planar_speed > 12.0
	var hard_brake: bool = absf(fwd_speed) > 16.0 \
		and signf(input_throttle) == -signf(fwd_speed) and absf(input_throttle) > 0.5
	if cut_nitro or hard_brake:
		_backfire_cooldown = 0.45
		sound.call("play_backfire", global_position)
	_prev_nitro = input_nitro


# ---------------------------------------------------------------------------
# COSMÉTIQUE (clients uniquement)
# ---------------------------------------------------------------------------

func _bind_local_view() -> void:
	# owner_peer_id arrive via le paquet de spawn : on ne peut pas s'y fier dans
	# _ready(), d'où cette liaison paresseuse.
	if _local_view_ready or _headless or not is_local_player():
		return
	_local_view_ready = true

	_camera = preload("res://scenes/camera/chase_camera.tscn").instantiate() as Camera3D
	add_child(_camera)
	_camera.set("target", self)
	_camera.current = true

	# Le HUD est créé une seule fois par l'arène : on s'y raccroche.
	_hud = get_tree().get_first_node_in_group("hud") as CanvasLayer
	if _hud:
		_hud.call("update_health", current_health, max_health)


func _cosmetic_step(delta: float) -> void:
	_refresh_visual_color()
	_refresh_damage_stage(false)

	var forward: Vector3 = -global_transform.basis.z
	var right: Vector3 = global_transform.basis.x
	var planar: Vector3 = Vector3(velocity.x, 0.0, velocity.z)
	var fwd_speed: float = planar.dot(forward)
	var lat_speed: float = planar.dot(right)

	if _visuals:
		_visuals.animate_wheels(input_steering, fwd_speed, delta)
		# Freinage = commande opposée au sens de marche, ou frein à main.
		_visuals.set_braking(input_handbrake
			or (absf(fwd_speed) > 2.0 and signf(input_throttle) == -signf(fwd_speed)))

	var sliding: bool = absf(lat_speed) > 5.0 and planar.length() > 6.0 and not is_dead
	for emitter: CPUParticles3D in _drift_smoke:
		emitter.emitting = sliding

	var boosting: bool = input_nitro and not is_overheated and not is_dead
	for flame: CPUParticles3D in _nitro_flames:
		flame.emitting = boosting

	# Traces de gomme plaquées au sol sous les roues arrière.
	_skid_cooldown -= delta
	if sliding and _skid_cooldown <= 0.0 and is_on_floor():
		_skid_cooldown = 0.045
		_drop_skidmark(-0.88)
		_drop_skidmark(0.88)

	if _camera:
		_camera.set("boosting", boosting)

	_update_audio(delta, planar.length(), lat_speed, fwd_speed)

	if _hud and is_local_player():
		_hud.call("update_speed", planar.length())
		_hud.call("update_heat", heat, is_overheated)


func _drop_skidmark(lateral_offset: float) -> void:
	var arena: Node = get_tree().current_scene
	if not arena:
		return
	var mark: Node3D = SKIDMARK_SCENE.instantiate() as Node3D
	var basis_ref: Basis = global_transform.basis
	var spot: Vector3 = global_position + basis_ref.x * lateral_offset + basis_ref.z * 1.22
	# Gomme plaquée au sol (Y = 0.02) et alignée sur le cap du véhicule.
	mark.position = Vector3(spot.x, 0.02, spot.z)
	mark.rotation = Vector3(-PI * 0.5, global_rotation.y, 0.0)
	arena.add_child(mark)


func _refresh_visual_color() -> void:
	if _built_color_index == color_index or not _visuals:
		return
	_built_color_index = color_index
	_visuals.build(color_index)


func _refresh_damage_stage(force: bool) -> void:
	var ratio: float = current_health / max_health if max_health > 0.0 else 0.0
	var stage: int = 0
	if ratio <= 0.25:
		stage = 3
	elif ratio <= 0.50:
		stage = 2
	elif ratio <= 0.75:
		stage = 1

	if stage == _applied_stage and not force:
		return
	_applied_stage = stage

	if _visuals:
		_visuals.set_damage_stage(stage)
	if _engine_smoke:
		_engine_smoke.emitting = stage >= 2 and not is_dead
	if _engine_fire:
		_engine_fire.emitting = stage >= 3 and not is_dead


func _reset_visuals() -> void:
	_applied_stage = -1
	_refresh_damage_stage(true)
	if _visuals:
		_visuals.visible = true


## Éclat d'étincelles + secousse caméra pour tous les clients à portée.
func _broadcast_impact(where: Vector3, trauma: float, severity: int = 1) -> void:
	if not multiplayer.is_server():
		return
	show_impact.rpc(where, trauma, severity)


## severity : 0 = frottement (micro-étincelles) · 1 = choc modéré
##            2 = impact lourd (gerbe + débris de carrosserie détachés)
@rpc("authority", "call_local", "unreliable")
func show_impact(where: Vector3, trauma: float, severity: int) -> void:
	if _headless:
		return
	var arena: Node = get_tree().current_scene
	if arena:
		var sparks: CPUParticles3D = SPARKS_SCENE.instantiate() as CPUParticles3D
		# Placer AVANT l'entrée dans l'arbre : les particules explosives émettent
		# dès la première frame, un repositionnement après coup serait visible.
		sparks.position = where
		match severity:
			0:
				sparks.amount = 8
				sparks.lifetime = 0.22
				sparks.initial_velocity_max = 3.5
				sparks.scale_amount_max = 0.6
			2:
				sparks.amount = 70
				sparks.lifetime = 0.55
				sparks.initial_velocity_max = 15.0
				sparks.scale_amount_max = 2.2
		arena.add_child(sparks)

		# Détachement de pièces : uniquement sur impact lourd.
		if severity >= 2:
			var debris: CPUParticles3D = DEBRIS_SCENE.instantiate() as CPUParticles3D
			debris.amount = 18
			debris.lifetime = 1.1
			debris.initial_velocity_max = 8.0
			debris.position = where
			arena.add_child(debris)

	# Le frottement ne doit ni claquer ni secouer la caméra.
	if severity > 0:
		var sound: Node = get_node_or_null("/root/SoundManager")
		if sound and sound.has_method("play_impact"):
			sound.call("play_impact", where, 0.3 if severity == 1 else 1.0)
	if _camera and _camera.has_method("add_trauma"):
		_camera.call("add_trauma", trauma)


func _spawn_debris() -> void:
	if _visuals:
		_visuals.visible = false
	if _engine_smoke:
		_engine_smoke.emitting = false
	if _engine_fire:
		_engine_fire.emitting = false
	var arena: Node = get_tree().current_scene
	if not arena:
		return
	var debris: CPUParticles3D = DEBRIS_SCENE.instantiate() as CPUParticles3D
	debris.position = global_position + Vector3.UP * 0.6
	arena.add_child(debris)
	if _camera and _camera.has_method("add_trauma"):
		_camera.call("add_trauma", 0.8)
