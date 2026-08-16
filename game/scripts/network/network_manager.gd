extends Node

## Autoload pilotant les trois modes d'exécution :
##  - DEDICATED : serveur headless Docker (`--headless`, port UDP 7777).
##  - CLIENT    : client ENet qui rejoint une arène distante.
##  - SOLO      : entraînement local hors-ligne (OfflineMultiplayerPeer + 4 bots IA).
##
## Le serveur est autoritatif : toutes les voitures — joueurs comme bots — ont
## l'autorité multijoueur 1. Les clients n'envoient que des entrées.

# Preload explicite : ne pas dépendre du cache de classes globales.
const Car = preload("res://scripts/cars/car.gd")

enum Mode { IDLE, DEDICATED, CLIENT, SOLO }
## Niveau jouable sélectionné au lancement (menu principal ou ligne de commande).
enum Level { ARENA_DERBY, RACE_FIGURE8 }

const DEFAULT_PORT: int = 7777
const DEFAULT_ADDRESS: String = "127.0.0.1"
const MAX_PLAYERS: int = 16
const ARENA_SCENE: String = "res://scenes/arenas/main.tscn"
const CIRCUIT_SCENE: String = "res://scenes/tracks/circuit_figure8.tscn"
const CAR_SCENE_PATH: String = "res://scenes/cars/car.tscn"

const SPAWN_SLOTS: int = 8
const SPAWN_RADIUS: float = 24.0
const SPAWN_HEIGHT: float = 0.6            # surélévation anti-clipping au sol
const BOT_COUNT: int = 4

var mode: int = Mode.IDLE
var level: int = Level.ARENA_DERBY
var arena_ready: bool = false

var _car_scene: PackedScene = null
var _pending_peers: Array[int] = []
var _pending_bots: int = 0
## Effectif de bots du mode solo, mémorisé pour pouvoir REJOUER : recharger la
## scène seule relancerait le décompte sur une piste vide, puisque les listes
## d'attente sont consommées au premier peuplement.
var solo_bot_count: int = 0
var _next_slot: int = 0
var _next_color: int = 0
var _tick_counter: int = 0


func _ready() -> void:
	_car_scene = load(CAR_SCENE_PATH) as PackedScene

	var args: PackedStringArray = _all_arguments()

	# Le runner de bot headless gère sa propre connexion : ne rien faire ici.
	for arg: String in args:
		if arg.contains("bot_runner"):
			print("[NetworkManager] Scène bot_runner détectée : autoload en veille.")
			return

	var port: int = DEFAULT_PORT
	var port_arg: String = _argument_value("--port=")
	if not port_arg.is_empty():
		port = port_arg.to_int()

	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

	# `--race` sélectionne le circuit Figure-8 (serveur dédié comme solo).
	if args.has("--race"):
		level = Level.RACE_FIGURE8

	if args.has("--solo"):
		# Point d'entrée sans interface (smoke test headless).
		call_deferred("start_solo_training", level)
		return

	if _is_dedicated(args):
		start_dedicated_server(port)
		return

	var connect_arg: String = _argument_value("--connect=")
	if not connect_arg.is_empty():
		join_game(connect_arg, port)
		return

	print("[NetworkManager] Client en attente : menu principal actif.")


func _physics_process(_delta: float) -> void:
	if mode != Mode.DEDICATED and mode != Mode.SOLO:
		return
	_tick_counter += 1
	if _tick_counter >= 300:      # toutes les 5 s à 60 Hz
		_tick_counter = 0
		log_active_players()


# ---------------------------------------------------------------------------
# ARGUMENTS
# ---------------------------------------------------------------------------

func _all_arguments() -> PackedStringArray:
	var args: PackedStringArray = OS.get_cmdline_args()
	args.append_array(OS.get_cmdline_user_args())
	return args


func _argument_value(prefix: String) -> String:
	for arg: String in _all_arguments():
		if arg.begins_with(prefix):
			return arg.substr(prefix.length())
	return ""


func _is_dedicated(args: PackedStringArray) -> bool:
	return DisplayServer.get_name() == "headless" \
		or args.has("--server") \
		or OS.has_feature("dedicated_server")


# ---------------------------------------------------------------------------
# DÉMARRAGE DES MODES
# ---------------------------------------------------------------------------

func start_dedicated_server(port: int) -> void:
	var peer: ENetMultiplayerPeer = ENetMultiplayerPeer.new()
	var err: Error = peer.create_server(port, MAX_PLAYERS)
	if err != OK:
		push_error("[NetworkManager] Impossible d'ouvrir le serveur sur le port %d (erreur %d)." % [port, err])
		return
	multiplayer.multiplayer_peer = peer
	mode = Mode.DEDICATED
	print("[NetworkManager] Serveur dédié actif sur le port UDP ", port)
	_load_arena()


func join_game(ip: String, port: int = DEFAULT_PORT) -> void:
	var address: String = ip.strip_edges()
	if address.is_empty():
		address = DEFAULT_ADDRESS

	var peer: ENetMultiplayerPeer = ENetMultiplayerPeer.new()
	var err: Error = peer.create_client(address, port)
	if err != OK:
		push_error("[NetworkManager] Connexion impossible vers %s:%d (erreur %d)." % [address, port, err])
		return
	multiplayer.multiplayer_peer = peer
	mode = Mode.CLIENT
	print("[NetworkManager] Connexion à l'arène : ", address, ":", port)
	_load_arena()


func level_scene_path() -> String:
	return CIRCUIT_SCENE if level == Level.RACE_FIGURE8 else ARENA_SCENE


func start_solo_training(selected_level: int = Level.ARENA_DERBY) -> void:
	level = selected_level
	print("[NetworkManager] Entraînement solo : arène locale + ", BOT_COUNT, " bots IA.")
	# Pair hors-ligne : get_unique_id() == 1, is_server() == true, aucun socket
	# ouvert. Bien plus sûr que de re-binder le port 7777 en local.
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	mode = Mode.SOLO
	solo_bot_count = BOT_COUNT
	_load_arena()


func _load_arena() -> void:
	arena_ready = false
	get_tree().call_deferred("change_scene_to_file", level_scene_path())


## Appelé par arena.gd dès que le noeud `Players` est disponible dans l'arbre.
func on_arena_ready() -> void:
	arena_ready = true
	_next_slot = 0
	_next_color = 0

	if not is_server():
		return

	if mode == Mode.SOLO:
		# Le solo se re-peuple à CHAQUE chargement de scène : c'est ce qui rend
		# « Rejouer » possible sans état résiduel.
		_pending_peers.clear()
		_pending_peers.append(1)
		_pending_bots = solo_bot_count
	elif mode == Mode.DEDICATED:
		# Rattraper les pairs qui se sont connectés avant le chargement de la scène.
		for id: int in multiplayer.get_peers():
			if not _pending_peers.has(id):
				_pending_peers.append(id)

	for id: int in _pending_peers:
		spawn_player(id)
	_pending_peers.clear()

	for i: int in _pending_bots:
		spawn_bot("Bot_%d" % (i + 1))
	_pending_bots = 0

	log_active_players()


## Relance la manche en cours en rechargeant le niveau : `on_arena_ready()`
## repeuple ensuite la grille.
func restart_round() -> void:
	arena_ready = false
	get_tree().call_deferred("reload_current_scene")


## Retour au menu principal : le pair doit être libéré et le mode remis à IDLE,
## faute de quoi main_menu.gd se croit en session et ne câble pas ses boutons.
func leave_to_menu() -> void:
	arena_ready = false
	_pending_peers.clear()
	_pending_bots = 0
	solo_bot_count = 0
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null
	mode = Mode.IDLE
	level = Level.ARENA_DERBY
	get_tree().call_deferred("change_scene_to_file", "res://scenes/ui/main_menu.tscn")


func is_server() -> bool:
	return multiplayer.multiplayer_peer != null and multiplayer.is_server()


# ---------------------------------------------------------------------------
# SIGNAUX RÉSEAU
# ---------------------------------------------------------------------------

func _on_peer_connected(id: int) -> void:
	print("[NetworkManager] Pair connecté : ", id)
	if not is_server():
		return
	if arena_ready:
		spawn_player(id)
	elif not _pending_peers.has(id):
		_pending_peers.append(id)


func _on_peer_disconnected(id: int) -> void:
	print("[NetworkManager] Pair déconnecté : ", id)
	_pending_peers.erase(id)
	if is_server():
		despawn_player(id)


func _on_connected_to_server() -> void:
	print("[NetworkManager] Connecté au serveur avec l'ID ", multiplayer.get_unique_id())


func _on_connection_failed() -> void:
	push_warning("[NetworkManager] Échec de connexion au serveur.")
	multiplayer.multiplayer_peer = null
	mode = Mode.IDLE


func _on_server_disconnected() -> void:
	push_warning("[NetworkManager] Serveur déconnecté.")
	multiplayer.multiplayer_peer = null
	mode = Mode.IDLE


# ---------------------------------------------------------------------------
# INSTANCIATION DES VÉHICULES
# ---------------------------------------------------------------------------

func get_players_container() -> Node:
	var scene: Node = get_tree().current_scene
	if not scene:
		return null
	return scene.get_node_or_null("Players")


func spawn_player(id: int) -> void:
	_spawn_car(str(id), id)


func spawn_bot(bot_name: String) -> void:
	_spawn_car(bot_name, 0)


func _spawn_car(node_name: String, peer_id: int) -> void:
	if not is_server():
		return

	if not _car_scene:
		_car_scene = load(CAR_SCENE_PATH) as PackedScene
	if not _car_scene:
		push_error("[NetworkManager] car.tscn introuvable : instanciation annulée.")
		return

	var container: Node = get_players_container()
	if not container:
		push_error("[NetworkManager] Noeud 'Players' absent de la scène courante.")
		return

	if container.has_node(NodePath(node_name)):
		print("[NetworkManager] Véhicule déjà présent pour : ", node_name)
		return

	var car: Car = _car_scene.instantiate() as Car
	car.name = node_name

	# Emplacement séquentiel : deux véhicules ne peuvent jamais partager le même
	# point de départ. La GÉOMÉTRIE est fournie par le niveau (cercle radial en
	# arène, grille en quinconce sur la ligne de départ en course).
	var slot: int = _next_slot
	_next_slot += 1
	var spawn_xf: Transform3D = _spawn_transform_for(slot)

	# Toutes les propriétés doivent être posées AVANT add_child() : c'est à cet
	# instant que MultiplayerSpawner capture l'état de spawn envoyé aux clients.
	# Le conteneur Players étant à l'identité, position == global_position.
	car.owner_peer_id = peer_id
	car.color_index = _next_color
	car.current_health = car.max_health
	car.is_dead = false
	car.position = spawn_xf.origin
	car.rotation = Vector3(0.0, spawn_xf.basis.get_euler().y, 0.0)
	# Le serveur reste autoritaire sur la physique et les dégâts de TOUS les véhicules.
	car.set_multiplayer_authority(1)
	_next_color += 1

	container.add_child(car, true)

	# Le niveau peut avoir besoin d'initialiser le véhicule (mode course :
	# inscription au classement + verrouillage si le décompte est en cours).
	var scene: Node = get_tree().current_scene
	if scene and scene.has_method("on_car_spawned"):
		scene.call("on_car_spawned", car)

	print("[SPAWN SUCCESS] Véhicule instancié : ", node_name, " (peer ", peer_id, ", slot ", slot, ")")


## Position de grille demandée au niveau, avec repli radial si la scène courante
## n'implémente pas l'interface.
func _spawn_transform_for(slot: int) -> Transform3D:
	var scene: Node = get_tree().current_scene
	if scene and scene.has_method("get_spawn_transform"):
		return scene.call("get_spawn_transform", slot) as Transform3D
	var angle: float = float(slot % SPAWN_SLOTS) * TAU / float(SPAWN_SLOTS)
	var origin: Vector3 = Vector3(SPAWN_RADIUS * cos(angle), SPAWN_HEIGHT, SPAWN_RADIUS * sin(angle))
	return Transform3D(Basis(Vector3.UP, atan2(origin.x, origin.z)), origin)


func despawn_player(id: int) -> void:
	var container: Node = get_players_container()
	if not container:
		return
	var car: Node = container.get_node_or_null(NodePath(str(id)))
	if car:
		car.queue_free()
		print("[NetworkManager] Véhicule retiré pour le pair ", id)


func log_active_players() -> void:
	var container: Node = get_players_container()
	if not container:
		print("[SERVER] Tick physique actif - Aucune arène chargée.")
		return
	var report: PackedStringArray = PackedStringArray()
	for child: Node in container.get_children():
		var car: Car = child as Car
		if not car:
			continue
		report.append("%s=%d%s@%.0fm/s" % [
			car.name,
			int(car.current_health),
			"(KO)" if car.is_dead else "",
			car.velocity.length()
		])
	print("[SERVER] Tick physique actif - Véhicules en arène : ",
		container.get_child_count(), " | ", " ".join(report))
