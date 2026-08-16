extends Node3D

## Racine de l'arène. Deux rôles :
##  1. Signaler au NetworkManager que le conteneur `Players` est prêt (ce qui
##     supprime toute course de type « attendre 2 frames après change_scene »).
##  2. Servir de relais réseau pour le killfeed partagé.

const HUD_SCENE: String = "res://scenes/ui/hud.tscn"

var _headless: bool = false


func _ready() -> void:
	_headless = DisplayServer.get_name() == "headless"

	if not _headless:
		var hud: CanvasLayer = load(HUD_SCENE).instantiate() as CanvasLayer
		hud.name = "ArenaHUD"
		add_child(hud)
		hud.add_to_group("hud")

	var network: Node = get_node_or_null("/root/NetworkManager")
	if network and network.has_method("on_arena_ready"):
		network.call("on_arena_ready")


# ---------------------------------------------------------------------------
# INTERFACE DE NIVEAU
# Implémentée par chaque scène jouable (arène, circuit). NetworkManager et
# car.gd interrogent la scène courante au lieu de coder en dur une géométrie :
# sans cela, les limites ±44 m de l'arène téléporteraient en boucle les
# véhicules d'un circuit de 140 m.
# ---------------------------------------------------------------------------

## Grille de départ radiale : 8 emplacements sur un cercle de 24 m, tournés vers
## le centre. `slot` est séquentiel, donc jamais deux véhicules au même endroit.
func get_spawn_transform(slot: int) -> Transform3D:
	var angle: float = float(slot % 8) * TAU / 8.0
	var origin: Vector3 = Vector3(24.0 * cos(angle), 0.6, 24.0 * sin(angle))
	# L'avant du véhicule est -Z : on l'oriente vers le centre.
	return Transform3D(Basis(Vector3.UP, atan2(origin.x, origin.z)), origin)


## Réinsertion après destruction ou sortie de limites : point radial aléatoire.
func get_recovery_transform(_from_position: Vector3) -> Transform3D:
	var angle: float = randf() * TAU
	var origin: Vector3 = Vector3(24.0 * cos(angle), 0.6, 24.0 * sin(angle))
	return Transform3D(Basis(Vector3.UP, atan2(origin.x, origin.z)), origin)


## Volume hors duquel un véhicule est considéré comme éjecté.
func get_world_bounds() -> AABB:
	return AABB(Vector3(-44.0, -4.0, -44.0), Vector3(88.0, 12.0, 88.0))


## Diffuse une ligne de killfeed à tous les pairs (appelé côté serveur).
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
