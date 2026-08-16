extends Node

## Client bot headless : se connecte au serveur dédié comme un vrai joueur et
## n'émet que des entrées (le serveur reste seul autoritaire sur la physique).
## Utilisé par le profil `test` du docker-compose pour charger l'arène.

# Preload explicite : ne pas dépendre du cache de classes globales.
const Car = preload("res://scripts/cars/car.gd")

const DEFAULT_PORT: int = 7777
const DEFAULT_ADDRESS: String = "127.0.0.1"
const RAM_RANGE: float = 32.0
const INPUT_INTERVAL: float = 0.05

var peer_id: int = 0

var _input_accumulator: float = 0.0
var _report_accumulator: float = 0.0
var _stuck_timer: float = 0.0
var _reverse_timer: float = 0.0
var _escape_steer: float = 0.85


func _ready() -> void:
	print("[BOT] Initialisation du client bot headless...")
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

	var ip: String = DEFAULT_ADDRESS
	var port: int = DEFAULT_PORT
	var args: PackedStringArray = OS.get_cmdline_args()
	args.append_array(OS.get_cmdline_user_args())
	for arg: String in args:
		if arg.begins_with("--connect="):
			ip = arg.substr("--connect=".length())
		elif arg.begins_with("--port="):
			port = arg.substr("--port=".length()).to_int()

	_connect_to_server(ip, port)


func _connect_to_server(ip: String, port: int) -> void:
	var peer: ENetMultiplayerPeer = ENetMultiplayerPeer.new()
	var err: Error = peer.create_client(ip, port)
	if err != OK:
		push_error("[BOT] Connexion impossible vers %s:%d (erreur %d)." % [ip, port, err])
		get_tree().quit(1)
		return
	multiplayer.multiplayer_peer = peer
	print("[BOT] Tentative de connexion à ", ip, ":", port, "...")


func _on_connected_to_server() -> void:
	peer_id = multiplayer.get_unique_id()
	print("[BOT] Connecté avec le peer_id ", peer_id, " - émission des entrées active.")


func _on_connection_failed() -> void:
	push_error("[BOT] Échec de connexion au serveur.")
	get_tree().quit(1)


func _on_server_disconnected() -> void:
	print("[BOT] Déconnecté du serveur.")
	get_tree().quit(0)


func _physics_process(delta: float) -> void:
	if peer_id == 0:
		return

	var my_car: Car = _own_car()
	if not my_car:
		return

	# Détection de blocage : deux clients se percutant de face restaient
	# verrouillés l'un contre l'autre à jouer du volant sans jamais se dégager.
	if _reverse_timer > 0.0:
		_reverse_timer -= delta
	elif my_car.velocity.length() < 2.0 and not my_car.is_dead:
		_stuck_timer += delta
		if _stuck_timer > 1.2:
			_stuck_timer = 0.0
			_reverse_timer = 1.4
			_escape_steer = 0.85 if randf() < 0.5 else -0.85
	else:
		_stuck_timer = maxf(0.0, _stuck_timer - delta)

	_input_accumulator += delta
	if _input_accumulator >= INPUT_INTERVAL:
		_input_accumulator = 0.0
		_send_inputs(my_car)

	_report_accumulator += delta
	if _report_accumulator >= 1.0:
		_report_accumulator = 0.0
		var health: String = "DÉTRUIT" if my_car.is_dead \
			else "HP: %d/%d" % [int(my_car.current_health), int(my_car.max_health)]
		print("[BOT] Pos: ", my_car.global_position.snapped(Vector3.ONE * 0.1),
			" | Vitesse: %.1f m/s | %s" % [my_car.velocity.length(), health])


func _players_node() -> Node:
	var scene: Node = get_tree().current_scene
	return scene.get_node_or_null("Players") if scene else null


func _own_car() -> Car:
	var players: Node = _players_node()
	if not players:
		return null
	return players.get_node_or_null(NodePath(str(peer_id))) as Car


func _send_inputs(my_car: Car) -> void:
	if my_car.is_dead:
		my_car.update_inputs.rpc_id(1, 0.0, 0.0, false, false)
		return

	if _reverse_timer > 0.0:
		my_car.update_inputs.rpc_id(1, -1.0, _escape_steer, false, false)
		return

	# Cible : véhicule vivant le plus proche dans le rayon de charge.
	var target: Car = null
	var best_distance: float = RAM_RANGE
	var players: Node = _players_node()
	if players:
		for child: Node in players.get_children():
			if child == my_car or not (child is Car):
				continue
			var other: Car = child as Car
			if other.is_dead:
				continue
			var distance: float = my_car.global_position.distance_to(other.global_position)
			if distance < best_distance:
				best_distance = distance
				target = other

	# Sans cible : converger vers le centre de l'arène pour recréer du contact.
	var goal: Vector3 = target.global_position if target else Vector3.ZERO
	var to_goal: Vector3 = goal - my_car.global_position
	to_goal.y = 0.0

	var distance_to_goal: float = to_goal.length()
	var throttle: float = 0.0
	var steering: float = 0.0
	var nitro: bool = false

	if distance_to_goal > 2.0:
		var direction: Vector3 = to_goal.normalized()
		var forward: Vector3 = -my_car.global_transform.basis.z
		var alignment: float = forward.dot(direction)
		# cross.y > 0 => cible à gauche => braquage positif (axe ui_left).
		steering = clampf(forward.cross(direction).y * 3.0, -1.0, 1.0)

		if alignment < -0.35 and distance_to_goal < 6.0:
			throttle = -0.8
			steering = -steering
		else:
			throttle = 1.0
			nitro = alignment > 0.9 and distance_to_goal > 14.0
	else:
		# Collé à la cible : reculer pour reprendre de l'élan plutôt que vibrer.
		throttle = -0.9
		steering = _escape_steer

	my_car.update_inputs.rpc_id(1, throttle, steering, nitro, false)
