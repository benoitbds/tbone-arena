extends Node

## Amorce du client bot headless.
##
## Le client DOIT charger exactement le même niveau que le serveur : les chemins
## de noeuds servent d'adresses aux RPC et au MultiplayerSpawner. Un bot resté
## sur l'arène (`/root/Main`) pendant que le serveur tourne sur le circuit
## (`/root/Circuit`) provoquait « Node not found: Circuit » à chaque paquet.
##
## Le pilote est donc déplacé sous `/root` — hors de la scène courante — pour
## survivre au `change_scene_to_file()` qui met le client sur le bon niveau.

const DRIVER_SCRIPT = preload("res://scripts/network/bot_client_runner.gd")

const ARENA_SCENE: String = "res://scenes/arenas/main.tscn"
const CIRCUIT_SCENE: String = "res://scenes/tracks/circuit_figure8.tscn"


func _ready() -> void:
	var args: PackedStringArray = OS.get_cmdline_args()
	args.append_array(OS.get_cmdline_user_args())
	var scene_path: String = CIRCUIT_SCENE if args.has("--race") else ARENA_SCENE

	var driver: Node = Node.new()
	driver.name = "BotDriver"
	driver.set_script(DRIVER_SCRIPT)
	# Ajout à la racine (et non à cette scène) : le pilote doit persister au
	# changement de niveau qui suit immédiatement.
	get_tree().root.call_deferred("add_child", driver)

	print("[BOT] Niveau ciblé : ", scene_path)
	get_tree().call_deferred("change_scene_to_file", scene_path)
