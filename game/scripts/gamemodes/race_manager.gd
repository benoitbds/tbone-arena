extends Node3D

## Mode Course sur circuit Figure-8 : racine du niveau + règles de course.
##
## Ce script cumule deux rôles, comme `arena.gd` pour le derby :
##  1. INTERFACE DE NIVEAU (grille de départ, réinsertion, limites du monde)
##     interrogée par network_manager.gd et car.gd ;
##  2. GESTIONNAIRE DE COURSE (tours, checkpoints, classement, décompte).
##
## Tout l'état de course est autoritatif SERVEUR et poussé aux clients par RPC
## (`sync_race_state`) plutôt que par le MultiplayerSynchronizer : ces valeurs
## ne changent que quelques fois par tour, une réplication continue serait du
## gaspillage de bande passante.

const CarScript = preload("res://scripts/cars/car.gd")
const CheckpointScript = preload("res://scripts/gamemodes/checkpoint.gd")
const HUD_SCENE: String = "res://scenes/ui/hud.tscn"

const TOTAL_LAPS: int = 3
const CHECKPOINT_COUNT: int = 8
const COUNTDOWN_SECONDS: float = 3.0
const GRID_ROW_SPACING: float = 7.0      # écart longitudinal entre rangées
const GRID_LATERAL: float = 3.0          # décalage en quinconce
const SPAWN_HEIGHT: float = 0.6
## Demi-largeur des portiques : 6 m => 12 m au total, soit exactement la piste
## (10 m de bitume, glissières à 6.2 m). Au-delà, un portique mordrait sur le
## dégagement ; en deçà, un véhicule plaqué au rail raterait la validation.
const CHECKPOINT_HALF_WIDTH: float = 6.0

## Abscisse curviligne de la LIGNE DE DÉPART/ARRIVÉE.
##
## Elle ne peut PAS valoir 0 : sur une lemniscate, les abscisses 0 et L/2 sont
## toutes deux le carrefour en X. Les checkpoints 0 et 4 s'y superposaient donc
## exactement, la séquence ne pouvait jamais avancer et aucun tour n'était
## validé. À 85 m, les 8 portiques sont à >26 m de la branche opposée et la
## grille de départ reste à >39 m du croisement.
const START_OFFSET: float = 85.0
const RACE_TIMEOUT: float = 420.0        # garde-fou absolu
## Délai laissé aux poursuivants après l'arrivée du vainqueur. Sans lui, la
## course ne se terminerait jamais dès qu'un véhicule est immobile (client
## headless sans pilote, joueur déconnecté) puisqu'il ne franchit jamais la ligne.
const FINISH_GRACE: float = 30.0

enum Phase { COUNTDOWN, RACING, FINISHED }

var phase: int = Phase.COUNTDOWN
var countdown: float = COUNTDOWN_SECONDS
var race_time: float = 0.0

## État de course par véhicule, indexé par nom de noeud (serveur uniquement).
## { lap, checkpoint, progress, finished, finish_time, best_lap, last_lap_start,
##   wrong_way, rank }
var entrants: Dictionary = {}

var _headless: bool = false
var _curve: Curve3D = null
var _checkpoint_offsets: PackedFloat32Array = PackedFloat32Array()
var _last_countdown_announced: int = -1
var _grace_remaining: float = -1.0
var _finish_order: Array[String] = []


func _ready() -> void:
	_headless = DisplayServer.get_name() == "headless"

	var path: Path3D = get_node_or_null("RacingLine") as Path3D
	if path and path.curve:
		_curve = path.curve
	else:
		push_error("[RaceManager] RacingLine absente : circuit inutilisable.")

	if not _headless:
		var hud: CanvasLayer = load(HUD_SCENE).instantiate() as CanvasLayer
		hud.name = "RaceHUD"
		add_child(hud)
		hud.add_to_group("hud")

	_build_checkpoints()

	var network: Node = get_node_or_null("/root/NetworkManager")
	if network and network.has_method("on_arena_ready"):
		network.call("on_arena_ready")


# ---------------------------------------------------------------------------
# INTERFACE DE NIVEAU
# ---------------------------------------------------------------------------

## Grille de départ en quinconce sur la ligne droite précédant la ligne
## d'arrivée : P1 en tête, les suivants décalés alternativement à gauche/droite.
func get_spawn_transform(slot: int) -> Transform3D:
	if not _curve:
		return Transform3D(Basis(), Vector3(0.0, SPAWN_HEIGHT, float(slot) * 5.0))

	var length: float = _curve.get_baked_length()
	# On recule depuis la ligne d'arrivée (offset 0) le long du tracé.
	var back: float = 18.0 + float(slot) * GRID_ROW_SPACING
	var offset: float = fposmod(START_OFFSET - back, length)
	var origin: Vector3 = _curve.sample_baked(offset)
	var forward: Vector3 = _tangent_at(offset)
	var side: Vector3 = forward.cross(Vector3.UP).normalized()

	# Quinconce : alternance gauche / droite d'une rangée à l'autre.
	var lateral: float = GRID_LATERAL * (1.0 if slot % 2 == 1 else -1.0)
	if slot == 0:
		lateral = 0.0
	origin += side * lateral
	origin.y = SPAWN_HEIGHT
	# Une rotation Y de θ envoie l'avant du véhicule (-Z local) sur
	# (-sin θ, 0, -cos θ). Pour l'aligner sur `forward` il faut donc
	# θ = atan2(-fx, -fz) : atan2(fx, fz) plaçait les véhicules à 180°,
	# nez à contresens sur la grille comme après chaque réinsertion.
	return Transform3D(Basis(Vector3.UP, atan2(-forward.x, -forward.z)), origin)


## Réinsertion sur la ligne idéale, orientée dans le SENS DE LA COURSE : un
## véhicule remis face au centre (comportement de l'arène) roulerait à contresens.
func get_recovery_transform(from_position: Vector3) -> Transform3D:
	if not _curve:
		return Transform3D(Basis(), Vector3(0.0, SPAWN_HEIGHT, 0.0))
	var offset: float = _closest_offset(from_position)
	var origin: Vector3 = _curve.sample_baked(offset)
	origin.y = SPAWN_HEIGHT
	var forward: Vector3 = _tangent_at(offset)
	# Une rotation Y de θ envoie l'avant du véhicule (-Z local) sur
	# (-sin θ, 0, -cos θ). Pour l'aligner sur `forward` il faut donc
	# θ = atan2(-fx, -fz) : atan2(fx, fz) plaçait les véhicules à 180°,
	# nez à contresens sur la grille comme après chaque réinsertion.
	return Transform3D(Basis(Vector3.UP, atan2(-forward.x, -forward.z)), origin)


## Circuit de 140 × 80 m : les limites de l'arène (±44 m) téléporteraient en
## boucle tous les véhicules des boucles extérieures.
func get_world_bounds() -> AABB:
	return AABB(Vector3(-95.0, -4.0, -70.0), Vector3(190.0, 14.0, 140.0))


func broadcast_killfeed(message: String) -> void:
	if multiplayer.multiplayer_peer == null or not multiplayer.is_server():
		print("[KILLFEED] ", message)
		return
	push_killfeed.rpc(message)


@rpc("authority", "call_local", "reliable")
func push_killfeed(message: String) -> void:
	print("[KILLFEED] ", message)
	if _headless:
		return
	for hud: Node in get_tree().get_nodes_in_group("hud"):
		if hud.has_method("add_killfeed"):
			hud.call("add_killfeed", message)


# ---------------------------------------------------------------------------
# TRACÉ : ÉCHANTILLONNAGE ET CHECKPOINTS
# ---------------------------------------------------------------------------

func _tangent_at(offset: float) -> Vector3:
	var length: float = _curve.get_baked_length()
	var ahead: Vector3 = _curve.sample_baked(fposmod(offset + 1.0, length))
	var here: Vector3 = _curve.sample_baked(fposmod(offset, length))
	var forward: Vector3 = ahead - here
	forward.y = 0.0
	if forward.length_squared() < 0.0001:
		return Vector3.FORWARD
	return forward.normalized()


## Abscisse curviligne du point de la courbe le plus proche.
## ATTENTION : au carrefour en X, deux branches se superposent — cette fonction
## est réservée à la réinsertion (où l'ambiguïté est sans conséquence). La
## navigation des bots utilise un suivi monotone, cf. car.gd.
func _closest_offset(point: Vector3) -> float:
	var length: float = _curve.get_baked_length()
	var best_offset: float = 0.0
	var best_distance: float = INF
	var steps: int = 240
	for i: int in steps:
		var offset: float = float(i) / float(steps) * length
		var distance: float = _curve.sample_baked(offset).distance_squared_to(point)
		if distance < best_distance:
			best_distance = distance
			best_offset = offset
	return best_offset


## Checkpoints répartis à ABSCISSE CURVILIGNE constante (et non en paramètre de
## courbe) : la lemniscate a une vitesse paramétrique très variable et un pas
## uniforme donnerait des portiques visiblement de travers.
func _build_checkpoints() -> void:
	if not _curve:
		return
	var length: float = _curve.get_baked_length()
	var holder: Node3D = Node3D.new()
	holder.name = "Checkpoints"
	add_child(holder)

	_checkpoint_offsets = PackedFloat32Array()
	for i: int in CHECKPOINT_COUNT:
		var offset: float = fposmod(START_OFFSET + float(i) / float(CHECKPOINT_COUNT) * length, length)
		_checkpoint_offsets.append(offset)

		var origin: Vector3 = _curve.sample_baked(offset)
		var forward: Vector3 = _tangent_at(offset)

		var area: Area3D = Area3D.new()
		area.name = "Checkpoint%d" % i
		area.set_script(CheckpointScript)
		area.position = origin + Vector3(0.0, 1.6, 0.0)
		area.rotation.y = atan2(-forward.x, -forward.z)
		holder.add_child(area)

		var shape: CollisionShape3D = CollisionShape3D.new()
		var box: BoxShape3D = BoxShape3D.new()
		# Portique large et fin : impossible à contourner, impossible à rater.
		box.size = Vector3(CHECKPOINT_HALF_WIDTH * 2.0, 4.0, 1.2)
		shape.shape = box
		area.add_child(shape)

		area.call("setup", i, i == 0, self)


# ---------------------------------------------------------------------------
# DÉROULEMENT DE LA COURSE (serveur)
# ---------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if multiplayer.multiplayer_peer == null or not multiplayer.is_server():
		return

	match phase:
		Phase.COUNTDOWN:
			_tick_countdown(delta)
		Phase.RACING:
			race_time += delta
			_tick_racing(delta)


func _tick_countdown(delta: float) -> void:
	countdown -= delta
	var remaining: int = int(ceil(countdown))
	if remaining != _last_countdown_announced and remaining > 0:
		_last_countdown_announced = remaining
		announce.rpc(str(remaining), 0.9)

	if countdown <= 0.0:
		phase = Phase.RACING
		announce.rpc("DÉPART !", 1.4)
		print("[RACE] Départ donné — %d tours." % TOTAL_LAPS)
		_set_controls_locked(false)


func _set_controls_locked(locked: bool) -> void:
	for car: Node in _cars():
		car.set("controls_locked", locked)
		if locked:
			car.call("_store_inputs", 0.0, 0.0, false, false)


func _cars() -> Array[Node]:
	var result: Array[Node] = []
	var container: Node = get_node_or_null("Players")
	if not container:
		return result
	for child: Node in container.get_children():
		if child is CarScript:
			result.append(child)
	return result


func _tick_racing(delta: float) -> void:
	var cars: Array[Node] = _cars()

	for car: Node in cars:
		var key: String = str(car.name)
		var state: Dictionary = _ensure_entrant(key)
		if state["finished"]:
			continue
		_update_progress(car, state, delta)

	_update_rankings(cars)

	# --- Conditions de fin de course ---
	if race_time > RACE_TIMEOUT:
		print("[RACE] Temps limite atteint : clôture de la course.")
		_finish_race()
		return
	if cars.is_empty():
		return

	var pending: int = 0
	for car: Node in cars:
		if not bool(_ensure_entrant(str(car.name))["finished"]):
			pending += 1

	if pending == 0:
		_finish_race()
		return

	# Le vainqueur est arrivé : compte à rebours pour les poursuivants.
	if not _finish_order.is_empty():
		if _grace_remaining < 0.0:
			_grace_remaining = FINISH_GRACE
			announce.rpc("ARRIVÉE — %ds" % int(FINISH_GRACE), 2.0)
		else:
			_grace_remaining -= delta
			if _grace_remaining <= 0.0:
				print("[RACE] Délai d'arrivée écoulé : clôture de la course.")
				_finish_race()


func _ensure_entrant(key: String) -> Dictionary:
	if not entrants.has(key):
		entrants[key] = {
			"lap": 1,
			"checkpoint": -1,
			"progress": 0.0,
			"finished": false,
			"finish_time": 0.0,
			"best_lap": 0.0,
			"last_lap_start": 0.0,
			"wrong_way": false,
			"rank": 0,
		}
	return entrants[key]


## Progression = tour * 10000 + checkpoint * 1000 + avancée vers le suivant.
##
## La formule d'origine ajoutait la DISTANCE au prochain checkpoint, ce qui
## classait devant le véhicule le plus ÉLOIGNÉ de sa cible. On conserve la
## structure et les ordres de grandeur, en inversant le terme pour que la
## progression croisse bien avec l'avancement réel.
func _update_progress(car: Node, state: Dictionary, delta: float) -> void:
	var lap: int = int(state["lap"])
	var checkpoint: int = int(state["checkpoint"])
	var next_index: int = (checkpoint + 1) % CHECKPOINT_COUNT
	var next_position: Vector3 = _curve.sample_baked(_checkpoint_offsets[next_index])
	var distance: float = (car as Node3D).global_position.distance_to(next_position)

	state["progress"] = float(lap) * 10000.0 \
		+ float(maxi(checkpoint, 0)) * 1000.0 \
		+ clampf(999.0 - distance, 0.0, 999.0)

	# --- Détection du sens inverse ---
	var to_next: Vector3 = next_position - (car as Node3D).global_position
	to_next.y = 0.0
	var heading: Vector3 = -(car as Node3D).global_transform.basis.z
	var speed: float = (car.get("velocity") as Vector3).length()
	var going_backwards: bool = speed > 4.0 and to_next.length() > 3.0 \
		and heading.dot(to_next.normalized()) < -0.4
	var was_wrong: bool = bool(state["wrong_way"])
	state["wrong_way"] = going_backwards
	if going_backwards != was_wrong:
		_push_state(car, state)


func on_checkpoint_reached(body: Node3D, index: int) -> void:
	if phase != Phase.RACING or not (body is CarScript):
		return
	var key: String = str(body.name)
	var state: Dictionary = _ensure_entrant(key)
	if state["finished"]:
		return

	var current: int = int(state["checkpoint"])
	var expected: int = (current + 1) % CHECKPOINT_COUNT

	# Anti-demi-tour : seul le checkpoint SUIVANT dans l'ordre est validé.
	if index != expected:
		return

	# Le tour ne s'incrémente que sur la ligne d'arrivée (checkpoint 0) et
	# uniquement si le dernier portique du tour a bien été franchi. Sans cette
	# condition atomique, un véhicule repassant à 0 verrait sa progression
	# chuter sous celle d'un concurrent encore au checkpoint 7.
	if index == 0 and current == CHECKPOINT_COUNT - 1:
		var lap_time: float = race_time - float(state["last_lap_start"])
		state["last_lap_start"] = race_time
		if float(state["best_lap"]) <= 0.0 or lap_time < float(state["best_lap"]):
			state["best_lap"] = lap_time
		state["lap"] = int(state["lap"]) + 1
		state["checkpoint"] = 0

		if int(state["lap"]) > TOTAL_LAPS:
			state["finished"] = true
			state["finish_time"] = race_time
			state["lap"] = TOTAL_LAPS
			_finish_order.append(key)
			broadcast_killfeed("🏁 %s termine %de en %.1fs" % [
				body.call("display_name"), _finish_order.size(), race_time])
			print("[RACE] %s a terminé (%d/%d) en %.1fs" % [
				key, _finish_order.size(), _cars().size(), race_time])
	else:
		state["checkpoint"] = index

	_push_state(body, state)


func _update_rankings(cars: Array[Node]) -> void:
	var ordered: Array[Node] = cars.duplicate()
	ordered.sort_custom(func(a: Node, b: Node) -> bool:
		var sa: Dictionary = _ensure_entrant(str(a.name))
		var sb: Dictionary = _ensure_entrant(str(b.name))
		# Les véhicules ayant fini sont classés par ordre d'arrivée.
		if bool(sa["finished"]) != bool(sb["finished"]):
			return bool(sa["finished"])
		if bool(sa["finished"]) and bool(sb["finished"]):
			return float(sa["finish_time"]) < float(sb["finish_time"])
		return float(sa["progress"]) > float(sb["progress"]))

	for i: int in ordered.size():
		var state: Dictionary = _ensure_entrant(str(ordered[i].name))
		var new_rank: int = i + 1
		if int(state["rank"]) != new_rank:
			state["rank"] = new_rank
			_push_state(ordered[i], state)


func _push_state(car: Node, state: Dictionary) -> void:
	sync_race_state.rpc(
		str(car.name),
		int(state["lap"]),
		int(state["rank"]),
		_cars().size(),
		bool(state["wrong_way"]),
		bool(state["finished"]))


## Pousse l'état de course d'un véhicule à tous les pairs. Le HUD ne s'intéresse
## qu'à son propre véhicule, mais tous doivent recevoir la mise à jour pour que
## le podium final soit cohérent partout.
@rpc("authority", "call_local", "reliable")
func sync_race_state(car_name: String, lap: int, rank: int, total: int,
		wrong_way: bool, finished: bool) -> void:
	var container: Node = get_node_or_null("Players")
	if not container:
		return
	var car: Node = container.get_node_or_null(NodePath(car_name))
	if not car:
		return
	car.set("race_lap", lap)
	car.set("race_rank", rank)
	car.set("race_total", total)
	car.set("race_wrong_way", wrong_way)
	car.set("race_finished", finished)

	if _headless or not car.call("is_local_player"):
		return
	for hud: Node in get_tree().get_nodes_in_group("hud"):
		if hud.has_method("update_race"):
			hud.call("update_race", rank, total, lap, TOTAL_LAPS, wrong_way)


@rpc("authority", "call_local", "reliable")
func announce(text: String, duration: float) -> void:
	print("[RACE] ", text)
	if _headless:
		return
	for hud: Node in get_tree().get_nodes_in_group("hud"):
		if hud.has_method("show_announcement"):
			hud.call("show_announcement", text, duration)


func _finish_race() -> void:
	if phase == Phase.FINISHED:
		return
	phase = Phase.FINISHED
	_set_controls_locked(true)

	# Classement final : les arrivés dans l'ordre, puis les autres par progression.
	var ordered: Array[Node] = _cars()
	ordered.sort_custom(func(a: Node, b: Node) -> bool:
		var sa: Dictionary = _ensure_entrant(str(a.name))
		var sb: Dictionary = _ensure_entrant(str(b.name))
		if bool(sa["finished"]) != bool(sb["finished"]):
			return bool(sa["finished"])
		if bool(sa["finished"]) and bool(sb["finished"]):
			return float(sa["finish_time"]) < float(sb["finish_time"])
		return float(sa["progress"]) > float(sb["progress"]))

	var lines: PackedStringArray = PackedStringArray()
	print("[RACE] ===== CLASSEMENT FINAL =====")
	for i: int in ordered.size():
		var car: Node = ordered[i]
		var state: Dictionary = _ensure_entrant(str(car.name))
		var best: float = float(state["best_lap"])
		var status: String = "%.1fs" % float(state["finish_time"]) if bool(state["finished"]) \
			else "tour %d/%d" % [int(state["lap"]), TOTAL_LAPS]
		var line: String = "%d. %s — %s — meilleur tour %s" % [
			i + 1,
			car.call("display_name"),
			status,
			("%.1fs" % best) if best > 0.0 else "—",
		]
		lines.append(line)
		print("[RACE] ", line)
	print("[RACE] ============================")

	show_results.rpc("\n".join(lines))


@rpc("authority", "call_local", "reliable")
func show_results(podium: String) -> void:
	if _headless:
		return
	for hud: Node in get_tree().get_nodes_in_group("hud"):
		if hud.has_method("show_results"):
			hud.call("show_results", podium)


## Verrouillage initial : appelé par NetworkManager après chaque instanciation
## pour qu'un véhicule apparu pendant le décompte reste immobile lui aussi.
func on_car_spawned(car: Node) -> void:
	_ensure_entrant(str(car.name))
	car.set("race_mode", true)
	car.set("controls_locked", phase == Phase.COUNTDOWN)
