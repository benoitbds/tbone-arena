extends RigidBody3D

## Baril explosif central : déflagration + impulsion radiale au choc.
## La détonation est décidée par le serveur puis répliquée à tous les pairs.

# Preload explicite : ne pas dépendre du cache de classes globales.
const Car = preload("res://scripts/cars/car.gd")

const SPARKS_SCENE: PackedScene = preload("res://scenes/fx/sparks_impact.tscn")

const TRIGGER_SPEED: float = 9.0      # m/s de vitesse relative minimale
const BLAST_RADIUS: float = 12.0
const BLAST_IMPULSE: float = 38.0
const BLAST_DAMAGE: float = 32.0

var exploded: bool = false

var _headless: bool = false


func _ready() -> void:
	_headless = DisplayServer.get_name() == "headless"
	contact_monitor = true
	max_contacts_reported = 6
	body_entered.connect(_on_body_entered)


## Choc signalé par un autre corps RIGIDE (pile de pneus projetée, etc.).
## Les véhicules NE passent PAS par ici : voir try_detonate().
func _on_body_entered(body: Node) -> void:
	if exploded or not (body is RigidBody3D):
		return
	var other: RigidBody3D = body as RigidBody3D
	try_detonate((linear_velocity - other.linear_velocity).length())


## Point d'entrée appelé par Car._resolve_impacts().
##
## Un CharacterBody3D est cinématique : ses contacts ne sont jamais remontés au
## contact_monitor d'un RigidBody3D (body_entered ne rapportait que le sol). La
## détection doit donc venir du véhicule, qui dispose déjà de ses collisions de
## glissement autoritatives.
func try_detonate(impact_speed: float) -> void:
	if exploded or impact_speed < TRIGGER_SPEED:
		return
	# Seul le serveur arbitre la déflagration.
	if multiplayer.multiplayer_peer != null and not multiplayer.is_server():
		return

	exploded = true
	_apply_blast()
	if multiplayer.multiplayer_peer != null:
		detonate.rpc()
	else:
		detonate()


## Onde de choc + dégâts : serveur uniquement, avant la destruction du prop.
func _apply_blast() -> void:
	var scene: Node = get_tree().current_scene
	var players: Node = scene.get_node_or_null("Players") if scene else null
	if not players:
		return

	for child: Node in players.get_children():
		if not (child is Car):
			continue
		var car: Car = child as Car
		if car.is_dead:
			continue

		var to_car: Vector3 = car.global_position - global_position
		to_car.y = 0.0
		var distance: float = to_car.length()
		if distance >= BLAST_RADIUS or distance < 0.001:
			continue

		var falloff: float = (BLAST_RADIUS - distance) / BLAST_RADIUS
		car.velocity += to_car.normalized() * falloff * BLAST_IMPULSE
		car.velocity.y = 0.0
		car.impact_stun = maxf(car.impact_stun, 0.5 * falloff)
		car.take_damage(BLAST_DAMAGE * falloff, "Baril explosif", false)


@rpc("authority", "call_local", "reliable")
func detonate() -> void:
	exploded = true
	print("[BARREL] Déflagration au centre de l'arène !")

	if not _headless:
		var scene: Node = get_tree().current_scene
		if scene:
			var blast: CPUParticles3D = SPARKS_SCENE.instantiate() as CPUParticles3D
			blast.amount = 160
			blast.lifetime = 0.9
			blast.initial_velocity_min = 8.0
			blast.initial_velocity_max = 26.0
			blast.scale_amount_max = 4.0
			blast.color = Color(1.0, 0.35, 0.05)
			blast.position = global_position
			scene.add_child(blast)

		var sound: Node = get_node_or_null("/root/SoundManager")
		if sound and sound.has_method("play_crash_sound"):
			sound.call("play_crash_sound")

	queue_free()
