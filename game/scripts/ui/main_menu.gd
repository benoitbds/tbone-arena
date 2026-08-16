extends Control

const SETTINGS_PATH: String = "user://client_settings.cfg"
const FALLBACK_IP: String = "tbone-backend.baq.ovh"

@onready var ip_input: LineEdit = $VBoxContainer/IPInput
@onready var join_btn: Button = $VBoxContainer/JoinButton
@onready var solo_btn: Button = $VBoxContainer/SoloButton
@onready var race_btn: Button = $VBoxContainer/RaceButton

var _network: Node = null


func _ready() -> void:
	_network = get_node_or_null("/root/NetworkManager")

	# En mode serveur dédié / solo scripté, le NetworkManager charge lui-même
	# l'arène : le menu ne fait rien pour éviter un double change_scene.
	if _network and int(_network.get("mode")) != 0:   # 0 == Mode.IDLE
		return

	var config: ConfigFile = ConfigFile.new()
	var saved_ip: String = FALLBACK_IP
	if config.load(SETTINGS_PATH) == OK:
		saved_ip = str(config.get_value("network", "saved_ip", FALLBACK_IP))
	ip_input.text = saved_ip

	join_btn.pressed.connect(_on_join_pressed)
	solo_btn.pressed.connect(_on_solo_pressed)
	race_btn.pressed.connect(_on_race_pressed)


func _on_join_pressed() -> void:
	var ip: String = ip_input.text.strip_edges()
	if ip.is_empty():
		ip = FALLBACK_IP

	var config: ConfigFile = ConfigFile.new()
	config.set_value("network", "saved_ip", ip)
	config.save(SETTINGS_PATH)

	print("[MENU] Connexion à l'arène : ", ip)
	if _network:
		_network.call("join_game", ip, 7777)


func _on_solo_pressed() -> void:
	print("[MENU] Lancement de l'Arène Derby.")
	if _network:
		# 0 == NetworkManager.Level.ARENA_DERBY
		_network.call("start_solo_training", 0)


func _on_race_pressed() -> void:
	print("[MENU] Lancement de la Course Figure-8.")
	if _network:
		# 1 == NetworkManager.Level.RACE_FIGURE8
		_network.call("start_solo_training", 1)
