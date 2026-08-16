extends Node3D

## Modèle 3D procédural du stock-car + déformation évolutive.
## Ce noeud est purement cosmétique : il n'est jamais interrogé par la physique
## et reste totalement inerte sur un serveur headless (aucun mesh n'est bâti).

# Palette de carrosserie indexée (partagée serveur/clients via `color_index`).
const PALETTE: Array[Color] = [
	Color(0.05, 0.62, 0.95),
	Color(0.92, 0.16, 0.16),
	Color(0.98, 0.72, 0.06),
	Color(0.25, 0.85, 0.35),
	Color(0.70, 0.25, 0.92),
	Color(0.98, 0.45, 0.05),
	Color(0.10, 0.90, 0.80),
	Color(0.92, 0.92, 0.94),
]

# Position de repos des pièces mobiles, mémorisée pour pouvoir les remettre à neuf.
const HOOD_REST: Vector3 = Vector3(0.0, 0.60, -1.20)
const BUMPER_REST: Vector3 = Vector3(0.0, 0.34, -1.86)
const DOOR_L_REST: Vector3 = Vector3(-0.86, 0.46, 0.05)
const DOOR_R_REST: Vector3 = Vector3(0.86, 0.46, 0.05)

const TAIL_IDLE_ENERGY: float = 0.9
const TAIL_BRAKE_ENERGY: float = 4.0

var damage_stage: int = 0

var _built: bool = false
var _mat_body: StandardMaterial3D = null
var _mat_tail: StandardMaterial3D = null
var _hood: Node3D = null
var _bumper_front: Node3D = null
var _door_left: Node3D = null
var _door_right: Node3D = null
var _wheels_front: Array[Node3D] = []
var _wheels_rear: Array[Node3D] = []


func build(color_index: int) -> void:
	if _built:
		apply_color(color_index)
		return
	_built = true

	var body_color: Color = PALETTE[posmod(color_index, PALETTE.size())]

	# Carrosserie vernie : `clearcoat` seul est inerte, il faut l'activer.
	_mat_body = StandardMaterial3D.new()
	_mat_body.albedo_color = body_color
	_mat_body.metallic = 0.7
	_mat_body.roughness = 0.12
	_mat_body.clearcoat_enabled = true
	_mat_body.clearcoat = 1.0
	_mat_body.clearcoat_roughness = 0.05

	var mat_dark: StandardMaterial3D = StandardMaterial3D.new()
	mat_dark.albedo_color = Color(0.20, 0.20, 0.23)
	mat_dark.metallic = 0.35
	mat_dark.roughness = 0.72

	var mat_glass: StandardMaterial3D = StandardMaterial3D.new()
	# Verre fumé : l'albédo d'origine lisait 0.0017 de luminance linéaire — un
	# trou noir au milieu du véhicule — et roughness 0.04 ne renvoyait qu'un
	# reflet spéculaire ponctuel. Une rugosité plus élevée capte l'ambiante.
	mat_glass.albedo_color = Color(0.10, 0.10, 0.16)
	mat_glass.metallic = 0.95
	mat_glass.roughness = 0.12
	mat_glass.clearcoat_enabled = true
	mat_glass.clearcoat = 1.0
	mat_glass.clearcoat_roughness = 0.02

	var mat_steel: StandardMaterial3D = StandardMaterial3D.new()
	mat_steel.albedo_color = Color(0.70, 0.72, 0.76)
	mat_steel.metallic = 0.95
	mat_steel.roughness = 0.24

	var mat_engine: StandardMaterial3D = StandardMaterial3D.new()
	mat_engine.albedo_color = Color(0.44, 0.42, 0.40)
	mat_engine.metallic = 0.7
	mat_engine.roughness = 0.5

	_mat_tail = StandardMaterial3D.new()
	_mat_tail.albedo_color = Color(0.55, 0.05, 0.03)
	_mat_tail.metallic = 0.3
	_mat_tail.roughness = 0.25
	_mat_tail.emission_enabled = true
	_mat_tail.emission = Color(1.0, 0.10, 0.04)
	_mat_tail.emission_energy_multiplier = TAIL_IDLE_ENERGY
	var mat_tail: StandardMaterial3D = _mat_tail

	# --- Châssis profilé : bas large + flancs relevés ---
	_add_box("ChassisLower", Vector3(1.74, 0.30, 3.45), Vector3(0.0, 0.22, 0.0), _mat_body)
	_add_box("ChassisUpper", Vector3(1.60, 0.26, 2.20), Vector3(0.0, 0.48, 0.35), _mat_body)
	_add_box("Skirt", Vector3(1.82, 0.14, 3.10), Vector3(0.0, 0.10, 0.0), mat_dark)

	# --- Capot incliné (pièce détachable au stade 3) ---
	_hood = Node3D.new()
	_hood.name = "Hood"
	_hood.position = HOOD_REST
	add_child(_hood)
	var hood_plate: MeshInstance3D = _make_box(Vector3(1.52, 0.12, 1.30), mat_dark)
	hood_plate.name = "HoodPlate"
	hood_plate.material_override = _mat_body
	hood_plate.rotation_degrees.x = -5.0
	_hood.add_child(hood_plate)
	var hood_scoop: MeshInstance3D = _make_box(Vector3(0.55, 0.14, 0.50), mat_dark)
	hood_scoop.name = "HoodScoop"
	hood_scoop.position = Vector3(0.0, 0.12, 0.10)
	_hood.add_child(hood_scoop)

	# Bloc moteur, révélé quand le capot est arraché.
	_add_box("EngineBlock", Vector3(0.90, 0.42, 0.95), Vector3(0.0, 0.50, -1.15), mat_engine)

	# --- Habitacle / cockpit vitré ---
	_add_box("CabinFrame", Vector3(1.42, 0.52, 1.55), Vector3(0.0, 0.78, 0.10), _mat_body)
	_add_box("Windshield", Vector3(1.30, 0.44, 0.10), Vector3(0.0, 0.80, -0.66), mat_glass)
	_add_box("RearWindow", Vector3(1.30, 0.44, 0.10), Vector3(0.0, 0.80, 0.86), mat_glass)
	_add_box("SideGlassL", Vector3(0.08, 0.36, 1.35), Vector3(-0.70, 0.82, 0.10), mat_glass)
	_add_box("SideGlassR", Vector3(0.08, 0.36, 1.35), Vector3(0.70, 0.82, 0.10), mat_glass)
	_add_box("Roof", Vector3(1.34, 0.10, 1.45), Vector3(0.0, 1.02, 0.10), _mat_body)

	# --- Portières latérales (pivot au montant avant pour qu'elles pendent) ---
	_door_left = _make_door("DoorLeft", DOOR_L_REST, _mat_body, mat_dark)
	_door_right = _make_door("DoorRight", DOOR_R_REST, _mat_body, mat_dark)

	# --- Pare-chocs tubulaires noirs mat (push bars) ---
	_bumper_front = _make_push_bar("BumperFront", BUMPER_REST, mat_dark)
	var bumper_rear: Node3D = _make_push_bar("BumperRear", Vector3(0.0, 0.34, 1.86), mat_dark)
	bumper_rear.rotation_degrees.y = 180.0

	# --- Roues : pneu + jante acier ---
	var front_offsets: Array[Vector3] = [Vector3(-0.88, 0.36, -1.18), Vector3(0.88, 0.36, -1.18)]
	var rear_offsets: Array[Vector3] = [Vector3(-0.88, 0.36, 1.22), Vector3(0.88, 0.36, 1.22)]
	for offset in front_offsets:
		_wheels_front.append(_make_wheel("WheelF", offset, mat_dark, mat_steel))
	for offset in rear_offsets:
		_wheels_rear.append(_make_wheel("WheelR", offset, mat_dark, mat_steel))

	# --- Feux ---
	_add_box("TailLightL", Vector3(0.34, 0.14, 0.08), Vector3(-0.55, 0.50, 1.74), mat_tail)
	_add_box("TailLightR", Vector3(0.34, 0.14, 0.08), Vector3(0.55, 0.50, 1.74), mat_tail)
	_add_head_light(Vector3(-0.56, 0.46, -1.80))
	_add_head_light(Vector3(0.56, 0.46, -1.80))

	set_damage_stage(damage_stage)


func apply_color(color_index: int) -> void:
	if _mat_body:
		_mat_body.albedo_color = PALETTE[posmod(color_index, PALETTE.size())]


## Applique l'état de tôle froissée correspondant au palier de dégâts.
## 0: intact · 1: HP<=75% · 2: HP<=50% · 3: HP<=25%
func set_damage_stage(stage: int) -> void:
	damage_stage = stage
	if not _built:
		return

	# Capot : intact -> enfoncé -> arraché.
	if _hood:
		_hood.visible = stage < 3
		if stage >= 1:
			_hood.position = HOOD_REST + Vector3(0.06, -0.16, 0.08)
			_hood.rotation_degrees = Vector3(9.0, 3.0, -6.0)
		else:
			_hood.position = HOOD_REST
			_hood.rotation_degrees = Vector3.ZERO

	# Pare-chocs avant tordu.
	if _bumper_front:
		if stage >= 1:
			_bumper_front.position = BUMPER_REST + Vector3(-0.05, -0.06, 0.16)
			_bumper_front.rotation_degrees = Vector3(-7.0, 5.0, 11.0)
		else:
			_bumper_front.position = BUMPER_REST
			_bumper_front.rotation_degrees = Vector3.ZERO

	# Portières qui se décrochent et pendent.
	if _door_left:
		if stage >= 2:
			_door_left.position = DOOR_L_REST + Vector3(-0.22, -0.14, 0.0)
			_door_left.rotation_degrees = Vector3(0.0, -34.0, 24.0)
		else:
			_door_left.position = DOOR_L_REST
			_door_left.rotation_degrees = Vector3.ZERO
	if _door_right:
		if stage >= 2:
			_door_right.position = DOOR_R_REST + Vector3(0.26, -0.10, 0.0)
			_door_right.rotation_degrees = Vector3(0.0, 40.0, -19.0)
		else:
			_door_right.position = DOOR_R_REST
			_door_right.rotation_degrees = Vector3.ZERO


## Braquage visuel des roues avant (radians) + rotation de roulement.
func animate_wheels(steer_ratio: float, forward_speed: float, delta: float) -> void:
	if not _built:
		return
	var steer_angle: float = -steer_ratio * 0.5
	var roll: float = forward_speed * delta / 0.36
	for wheel in _wheels_front:
		wheel.rotation.y = steer_angle
		var hub: Node3D = wheel.get_child(0) as Node3D
		if hub:
			hub.rotate_x(roll)
	for wheel in _wheels_rear:
		var hub: Node3D = wheel.get_child(0) as Node3D
		if hub:
			hub.rotate_x(roll)


## Feux stop : bloom marqué au freinage, veilleuse sinon.
func set_braking(braking: bool) -> void:
	if _mat_tail:
		_mat_tail.emission_energy_multiplier = \
			TAIL_BRAKE_ENERGY if braking else TAIL_IDLE_ENERGY


func _make_box(size: Vector3, material: StandardMaterial3D) -> MeshInstance3D:
	var node: MeshInstance3D = MeshInstance3D.new()
	var mesh: BoxMesh = BoxMesh.new()
	mesh.size = size
	node.mesh = mesh
	node.material_override = material
	return node


func _add_box(node_name: String, size: Vector3, pos: Vector3, material: StandardMaterial3D) -> MeshInstance3D:
	var node: MeshInstance3D = _make_box(size, material)
	node.name = node_name
	node.position = pos
	add_child(node)
	return node


func _make_door(node_name: String, pos: Vector3, mat_panel: StandardMaterial3D, mat_trim: StandardMaterial3D) -> Node3D:
	var pivot: Node3D = Node3D.new()
	pivot.name = node_name
	pivot.position = pos
	add_child(pivot)

	var panel: MeshInstance3D = _make_box(Vector3(0.08, 0.46, 1.35), mat_panel)
	panel.name = "Panel"
	pivot.add_child(panel)

	var handle: MeshInstance3D = _make_box(Vector3(0.06, 0.06, 0.22), mat_trim)
	handle.name = "Handle"
	handle.position = Vector3(signf(pos.x) * 0.06, 0.10, 0.30)
	pivot.add_child(handle)
	return pivot


func _make_push_bar(node_name: String, pos: Vector3, material: StandardMaterial3D) -> Node3D:
	var pivot: Node3D = Node3D.new()
	pivot.name = node_name
	pivot.position = pos
	add_child(pivot)

	var main_tube: MeshInstance3D = MeshInstance3D.new()
	main_tube.name = "MainTube"
	var tube_mesh: CylinderMesh = CylinderMesh.new()
	tube_mesh.top_radius = 0.07
	tube_mesh.bottom_radius = 0.07
	tube_mesh.height = 1.76
	main_tube.mesh = tube_mesh
	main_tube.rotation_degrees.z = 90.0
	main_tube.material_override = material
	pivot.add_child(main_tube)

	var strut_offsets: Array[float] = [-0.62, 0.0, 0.62]
	for x: float in strut_offsets:
		var strut: MeshInstance3D = MeshInstance3D.new()
		var strut_mesh: CylinderMesh = CylinderMesh.new()
		strut_mesh.top_radius = 0.055
		strut_mesh.bottom_radius = 0.055
		strut_mesh.height = 0.46
		strut.mesh = strut_mesh
		strut.position = Vector3(x, 0.20, 0.0)
		strut.material_override = material
		pivot.add_child(strut)
	return pivot


func _make_wheel(node_name: String, pos: Vector3, mat_tire: StandardMaterial3D, mat_rim: StandardMaterial3D) -> Node3D:
	# Pivot (braquage) -> hub (roulement) -> pneu + jante.
	var pivot: Node3D = Node3D.new()
	pivot.name = node_name
	pivot.position = pos
	add_child(pivot)

	var hub: Node3D = Node3D.new()
	hub.name = "Hub"
	hub.rotation_degrees.z = 90.0
	pivot.add_child(hub)

	var tire: MeshInstance3D = MeshInstance3D.new()
	tire.name = "Tire"
	var tire_mesh: CylinderMesh = CylinderMesh.new()
	tire_mesh.top_radius = 0.36
	tire_mesh.bottom_radius = 0.36
	tire_mesh.height = 0.30
	tire.mesh = tire_mesh
	tire.material_override = mat_tire
	hub.add_child(tire)

	var rim: MeshInstance3D = MeshInstance3D.new()
	rim.name = "Rim"
	var rim_mesh: CylinderMesh = CylinderMesh.new()
	rim_mesh.top_radius = 0.21
	rim_mesh.bottom_radius = 0.21
	rim_mesh.height = 0.32
	rim.mesh = rim_mesh
	rim.material_override = mat_rim
	hub.add_child(rim)
	return pivot


func _add_head_light(pos: Vector3) -> void:
	var lamp: MeshInstance3D = MeshInstance3D.new()
	lamp.name = "HeadLampMesh"
	var lamp_mesh: BoxMesh = BoxMesh.new()
	lamp_mesh.size = Vector3(0.30, 0.16, 0.08)
	lamp.mesh = lamp_mesh
	var mat_lamp: StandardMaterial3D = StandardMaterial3D.new()
	mat_lamp.albedo_color = Color(1.0, 0.97, 0.85)
	mat_lamp.emission_enabled = true
	mat_lamp.emission = Color(1.0, 0.95, 0.8)
	mat_lamp.emission_energy_multiplier = 3.0
	lamp.material_override = mat_lamp
	lamp.position = pos
	add_child(lamp)

	var light: SpotLight3D = SpotLight3D.new()
	light.name = "HeadLight"
	light.position = pos + Vector3(0.0, 0.0, -0.06)
	# -Z est l'avant du véhicule : le cône par défaut pointe vers -Z, aucune rotation requise.
	light.spot_range = 18.0
	light.spot_angle = 34.0
	light.spot_attenuation = 0.8
	light.light_energy = 4.5
	light.light_color = Color(1.0, 0.96, 0.86)
	light.shadow_enabled = true
	add_child(light)
