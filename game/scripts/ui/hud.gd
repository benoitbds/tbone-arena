extends CanvasLayer

@onready var health_bar: ProgressBar = $Control/TopLeft/HealthBar
@onready var health_text: Label = $Control/TopLeft/HealthBar/HealthText
@onready var speed_text: Label = $Control/TopLeft/Speedometer
@onready var tbone_banner: Label = $Control/Center/TBoneBanner
@onready var killfeed_container: VBoxContainer = $Control/TopRight/KillfeedContainer

@onready var heat_bar: ProgressBar = $Control/TopLeft/NitroHeatBar
@onready var overheat_text: Label = $Control/TopLeft/NitroHeatBar/OverheatText

# --- Widgets du mode Course (masqués en derby) ---
@onready var race_box: VBoxContainer = $Control/TopRight/RaceBox
@onready var race_panel: PanelContainer = $Control/TopRight/RaceBoxPanel
@onready var position_label: Label = $Control/TopRight/RaceBox/PositionLabel
@onready var lap_label: Label = $Control/TopRight/RaceBox/LapLabel
@onready var wrong_way_label: Label = $Control/TopRight/RaceBox/WrongWayLabel
@onready var announce_label: Label = $Control/Center/AnnounceLabel
@onready var results_panel: PanelContainer = $Control/ResultsPanel
@onready var results_body: Label = $Control/ResultsPanel/Margin/VBox/ResultsBody
@onready var replay_button: Button = $Control/ResultsPanel/Margin/VBox/Buttons/ReplayButton
@onready var menu_button: Button = $Control/ResultsPanel/Margin/VBox/Buttons/MenuButton

var _announce_tween: Tween = null
var _last_lap_shown: int = 0

var tbone_timer: Timer

func _ready() -> void:
	tbone_banner.visible = false
	tbone_timer = Timer.new()
	tbone_timer.wait_time = 1.2
	tbone_timer.one_shot = true
	tbone_timer.timeout.connect(_on_tbone_timer_timeout)
	add_child(tbone_timer)
	
	race_box.visible = false
	race_panel.visible = false
	announce_label.visible = false
	results_panel.visible = false
	replay_button.pressed.connect(restart_round)
	menu_button.pressed.connect(return_to_menu)
	wrong_way_label.visible = false

	# Initial representations
	update_health(100.0, 100.0)
	update_speed(0.0)
	update_heat(0.0, false)

func update_health(current: float, max_h: float) -> void:
	if not health_bar or not health_text:
		return
	health_bar.max_value = max_h
	health_bar.value = current
	health_text.text = str(int(current)) + " / " + str(int(max_h)) + " HP"
	
	# Color modulation based on remaining HP percentage
	var ratio: float = current / max_h
	if ratio > 0.5:
		_tint_fill(health_bar, Color(0.25, 0.95, 0.35))
	elif ratio > 0.25:
		_tint_fill(health_bar, Color(1.0, 0.62, 0.08))
	else:
		_tint_fill(health_bar, Color(1.0, 0.22, 0.18))

func update_speed(speed: float) -> void:
	if not speed_text:
		return
	# Convert m/s to km/h for a standard arcade racing feel
	speed_text.text = str(int(speed * 3.6)) + " km/h"

func update_heat(current: float, is_overheated: bool) -> void:
	if not heat_bar or not overheat_text:
		return
		
	heat_bar.value = current
	overheat_text.visible = is_overheated
	
	if is_overheated:
		# Flash heat bar in red
		_tint_fill(heat_bar, Color(1.0, 0.15, 0.15))
		# Pulsing sine wave opacity for warning label
		overheat_text.modulate.a = 0.4 + sin(Time.get_ticks_msec() * 0.015) * 0.4
	else:
		# Interpolate color: Cyan/Blue (0) to Orange/Red (100)
		var ratio: float = current / 100.0
		_tint_fill(heat_bar, Color(0.15, 0.85, 1.0).lerp(Color(1.0, 0.45, 0.0), ratio))
		overheat_text.modulate.a = 1.0

## Colore uniquement la barre de remplissage, en dupliquant la StyleBox pour
## que les deux jauges gardent des teintes indépendantes.
func _tint_fill(bar: ProgressBar, color: Color) -> void:
	var fill: StyleBoxFlat = bar.get_theme_stylebox("fill") as StyleBoxFlat
	if not fill:
		bar.modulate = color
		return
	if not bar.has_meta("own_fill"):
		fill = fill.duplicate()
		bar.add_theme_stylebox_override("fill", fill)
		bar.set_meta("own_fill", true)
	fill.bg_color = color


func show_tbone_critical() -> void:
	if not tbone_banner or not tbone_timer:
		return
	tbone_banner.visible = true
	tbone_timer.start()
	
	# Flashing tween loop to create dynamic arcade critical banner
	var tween: Tween = create_tween()
	tween.tween_property(tbone_banner, "modulate", Color(1, 1, 0), 0.1) # Yellow
	tween.tween_property(tbone_banner, "modulate", Color(1, 0.1, 0.1), 0.1) # Bright Red
	tween.set_loops(6)

func _on_tbone_timer_timeout() -> void:
	if tbone_banner:
		tbone_banner.visible = false

func add_killfeed(msg: String) -> void:
	if not killfeed_container:
		return
	var label: Label = Label.new()
	label.text = msg
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	
	# Customize visual style of the killfeed line
	label.add_theme_color_override("font_shadow_color", Color.BLACK)
	label.add_theme_font_size_override("font_size", 16)
	
	killfeed_container.add_child(label)
	
	# Cap the list size
	if killfeed_container.get_child_count() > 6:
		killfeed_container.get_child(0).queue_free()
		
	# Smoothly fade out the killfeed message after 4 seconds
	var tween: Tween = create_tween()
	tween.tween_interval(4.0)
	tween.tween_property(label, "modulate:a", 0.0, 0.5)
	tween.tween_callback(label.queue_free)


# ---------------------------------------------------------------------------
# MODE COURSE
# ---------------------------------------------------------------------------

## Position, tour et alerte de sens inverse. Le widget reste invisible tant que
## le mode Course n'a rien poussé : le derby n'affiche donc rien de plus.
func update_race(rank: int, total: int, lap: int, total_laps: int, wrong_way: bool) -> void:
	if not race_box:
		return
	race_box.visible = true
	race_panel.visible = true

	var crown: String = "👑 " if rank == 1 else ""
	position_label.text = "%s%d/%d" % [crown, rank, maxi(total, 1)]
	position_label.modulate = Color(1.0, 0.85, 0.25) if rank == 1 else Color(1, 1, 1)

	lap_label.text = "TOUR %d/%d" % [mini(lap, total_laps), total_laps]
	wrong_way_label.visible = wrong_way

	# Alerte unique à l'entrée dans le dernier tour.
	if lap == total_laps and lap != _last_lap_shown:
		_last_lap_shown = lap
		lap_label.modulate = Color(1.0, 0.35, 0.2)
		show_announcement("DERNIER TOUR !", 1.8)
	elif lap != _last_lap_shown:
		_last_lap_shown = lap
		lap_label.modulate = Color(1, 1, 1)


## Bandeau central : décompte de départ, « DÉPART ! », « DERNIER TOUR ! ».
func show_announcement(text: String, duration: float) -> void:
	if not announce_label:
		return
	if _announce_tween and _announce_tween.is_valid():
		_announce_tween.kill()

	announce_label.text = text
	announce_label.visible = true
	announce_label.modulate = Color(1, 0.93, 0.4, 1)
	announce_label.scale = Vector2.ONE

	_announce_tween = create_tween()
	_announce_tween.tween_property(announce_label, "modulate:a", 1.0, 0.08)
	_announce_tween.tween_interval(maxf(0.1, duration - 0.35))
	_announce_tween.tween_property(announce_label, "modulate:a", 0.0, 0.27)
	_announce_tween.tween_callback(func() -> void: announce_label.visible = false)


## Écran de fin : podium complet (classement, temps, meilleur tour).
func show_results(podium: String) -> void:
	if not results_panel or not results_body:
		return
	results_body.text = podium
	results_panel.visible = true
	results_panel.modulate = Color(1, 1, 1, 0)
	var tween: Tween = create_tween()
	tween.tween_property(results_panel, "modulate:a", 1.0, 0.5)


## Raccourcis de fin de manche. Volontairement en _unhandled_input et gardés
## derrière la visibilité du podium : `ui_accept` inclut Espace, qui sert de
## Nitro en course — le capturer plus tôt relancerait la manche en pleine course.
func _unhandled_input(event: InputEvent) -> void:
	if not results_panel or not results_panel.visible:
		return
	if event.is_action_pressed("ui_accept"):
		get_viewport().set_input_as_handled()
		restart_round()
	elif event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		return_to_menu()


func restart_round() -> void:
	results_panel.visible = false
	var network: Node = get_node_or_null("/root/NetworkManager")
	# Le NetworkManager doit ré-amorcer la grille : recharger la scène seule
	# rejouerait le décompte sur une piste vide.
	if network and network.has_method("restart_round"):
		network.call("restart_round")
	else:
		get_tree().reload_current_scene()


func return_to_menu() -> void:
	results_panel.visible = false
	var network: Node = get_node_or_null("/root/NetworkManager")
	if network and network.has_method("leave_to_menu"):
		network.call("leave_to_menu")
	else:
		get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn")
