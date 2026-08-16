extends Area3D

## Portique de contrôle numéroté. Purement passif : il ne fait que signaler le
## passage d'un véhicule au RaceManager, qui seul décide de la validité (ordre,
## tour bouclé, sens de circulation).

var index: int = 0
var is_finish_line: bool = false

var _race_manager: Node = null


func _ready() -> void:
	monitoring = true
	monitorable = false
	body_entered.connect(_on_body_entered)


func setup(checkpoint_index: int, finish_line: bool, manager: Node) -> void:
	index = checkpoint_index
	is_finish_line = finish_line
	_race_manager = manager


func _on_body_entered(body: Node3D) -> void:
	# Seul le serveur arbitre la progression en course.
	if multiplayer.multiplayer_peer != null and not multiplayer.is_server():
		return
	if _race_manager and _race_manager.has_method("on_checkpoint_reached"):
		_race_manager.call("on_checkpoint_reached", body, index)
