extends Node3D

## Construit la géométrie du circuit à partir de la ligne idéale (`Path3D`).
##
## Tout est généré : écrire à la main plusieurs centaines de noeuds `.tscn`
## alignés sur une lemniscate serait ingérable et invérifiable.
##
## Découpage headless / client :
##  - les GLISSIÈRES (collision) sont bâties partout, le serveur en a besoin ;
##  - la piste, les vibreurs et les projecteurs sont purement visuels et ne
##    sont bâtis que sur un client.

## Demi-largeur de piste. Les branches de la lemniscate se rapprochent jusqu'à
## 16.3 m hors du carrefour : 5 m de demi-piste + rails à 6.2 m laissent ~3.9 m
## de dégagement entre branches opposées, sans recouvrement.
const HALF_WIDTH: float = 5.0
const RAIL_OFFSET: float = 6.2
const RAIL_HEIGHT: float = 1.6

## Rayon du carrefour en X laissé LIBRE de toute glissière : c'est précisément
## le croisement à niveau où doivent se produire les T-Bones.
const JUNCTION_RADIUS: float = 14.0

const SEGMENTS: int = 240          # échantillons le long de la courbe
const KERB_TILE: float = 2.4       # longueur d'un damier de vibreur
const KERB_CURVATURE: float = 0.012  # au-delà : virage assez serré pour un vibreur

const Surfaces = preload("res://scripts/tracks/surface_materials.gd")

## Emprise du décor hors piste (terre/gravier) autour du tracé.
const TERRAIN_SIZE: Vector2 = Vector2(250.0, 250.0)

var _headless: bool = false
var _curve: Curve3D = null


func _ready() -> void:
	_headless = DisplayServer.get_name() == "headless"
	var path: Path3D = get_node_or_null("../RacingLine") as Path3D
	if not path or not path.curve:
		push_error("[TrackBuilder] RacingLine/Curve3D introuvable : circuit non bâti.")
		return
	_curve = path.curve

	_build_guardrails()
	if not _headless:
		_build_terrain()
		_build_road_surface()
		_build_kerbs()
		_build_floodlights()


## Échantillonne la courbe à intervalle d'ABSCISSE CURVILIGNE (et non en `t`) :
## la lemniscate a une vitesse paramétrique très variable (70 à 106), un pas
## uniforme en `t` donnerait des segments de longueurs très inégales.
func _sample(index: int) -> Dictionary:
	var length: float = _curve.get_baked_length()
	var offset: float = fposmod(float(index) / float(SEGMENTS) * length, length)
	var here: Vector3 = _curve.sample_baked(offset)
	var ahead: Vector3 = _curve.sample_baked(fposmod(offset + 0.5, length))
	var forward: Vector3 = (ahead - here)
	forward.y = 0.0
	if forward.length_squared() < 0.0001:
		forward = Vector3.FORWARD
	forward = forward.normalized()
	return {
		"position": here,
		"forward": forward,
		"side": forward.cross(Vector3.UP).normalized(),
	}


## Nappe de terre/gravier débordant largement le tracé : sans elle, la piste
## flotte au-dessus d'un sol plat uniforme.
func _build_terrain() -> void:
	var ground: MeshInstance3D = MeshInstance3D.new()
	ground.name = "Terrain"
	var mesh: PlaneMesh = PlaneMesh.new()
	mesh.size = TERRAIN_SIZE
	mesh.subdivide_width = 32
	mesh.subdivide_depth = 32
	ground.mesh = mesh
	ground.material_override = Surfaces.make_gravel(Color(0.075, 0.068, 0.058), 34.0)
	# Juste sous le ruban d'asphalte (posé à +0.02).
	ground.position = Vector3(0.0, 0.012, 0.0)
	add_child(ground)


func _build_road_surface() -> void:
	var surface: SurfaceTool = SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)

	for i: int in SEGMENTS:
		var a: Dictionary = _sample(i)
		var b: Dictionary = _sample(i + 1)
		var a_pos: Vector3 = a["position"]
		var b_pos: Vector3 = b["position"]
		var a_side: Vector3 = a["side"]
		var b_side: Vector3 = b["side"]

		# Ruban légèrement au-dessus du sol pour éviter le z-fighting.
		var lift: Vector3 = Vector3(0.0, 0.02, 0.0)
		var a_l: Vector3 = a_pos - a_side * HALF_WIDTH + lift
		var a_r: Vector3 = a_pos + a_side * HALF_WIDTH + lift
		var b_l: Vector3 = b_pos - b_side * HALF_WIDTH + lift
		var b_r: Vector3 = b_pos + b_side * HALF_WIDTH + lift

		var v: float = float(i) * 0.5
		surface.set_uv(Vector2(0.0, v)); surface.add_vertex(a_l)
		surface.set_uv(Vector2(1.0, v)); surface.add_vertex(a_r)
		surface.set_uv(Vector2(1.0, v + 0.5)); surface.add_vertex(b_r)

		surface.set_uv(Vector2(0.0, v)); surface.add_vertex(a_l)
		surface.set_uv(Vector2(1.0, v + 0.5)); surface.add_vertex(b_r)
		surface.set_uv(Vector2(0.0, v + 0.5)); surface.add_vertex(b_l)

	surface.generate_normals()

	# Grain de bitume : normal map + carte de rugosité générées par bruit.
	var asphalt: StandardMaterial3D = Surfaces.make_asphalt(Color(0.105, 0.11, 0.125), 6.0)

	var road: MeshInstance3D = MeshInstance3D.new()
	road.name = "RoadSurface"
	road.mesh = surface.commit()
	road.material_override = asphalt
	add_child(road)


func _build_kerbs() -> void:
	var mat_red: StandardMaterial3D = Surfaces.make_kerb(Color(0.85, 0.12, 0.12), 21)
	var mat_white: StandardMaterial3D = Surfaces.make_kerb(Color(0.92, 0.92, 0.90), 42)

	var kerb_mesh: BoxMesh = BoxMesh.new()
	kerb_mesh.size = Vector3(1.1, 0.12, KERB_TILE)

	var holder: Node3D = Node3D.new()
	holder.name = "Kerbs"
	add_child(holder)

	var length: float = _curve.get_baked_length()
	var tiles: int = int(length / KERB_TILE)
	for i: int in tiles:
		var offset: float = float(i) * KERB_TILE
		var index: float = offset / length * float(SEGMENTS)
		var here: Dictionary = _sample(int(index))
		var pos: Vector3 = here["position"]
		var side: Vector3 = here["side"]
		var forward: Vector3 = here["forward"]

		# Vibreurs uniquement dans les courbes : la courbure locale est estimée
		# par l'écart angulaire entre deux échantillons voisins.
		var next: Dictionary = _sample(int(index) + 3)
		var next_forward: Vector3 = next["forward"]
		var curvature: float = forward.angle_to(next_forward)
		if curvature < KERB_CURVATURE:
			continue

		var material: StandardMaterial3D = mat_red if i % 2 == 0 else mat_white
		for sign_side: float in [-1.0, 1.0]:
			var tile: MeshInstance3D = MeshInstance3D.new()
			tile.mesh = kerb_mesh
			tile.material_override = material
			tile.position = pos + side * sign_side * (HALF_WIDTH + 0.55) + Vector3(0.0, 0.06, 0.0)
			tile.rotation.y = atan2(forward.x, forward.z)
			holder.add_child(tile)


## Doubles glissières : une lisse haute + une lisse basse sur chaque bord, en
## `StaticBody3D` unique porteur de toutes les collisions.
func _build_guardrails() -> void:
	var rails: StaticBody3D = StaticBody3D.new()
	rails.name = "Guardrails"
	add_child(rails)

	var mat_rail: StandardMaterial3D = null
	var rail_mesh: BoxMesh = null
	if not _headless:
		mat_rail = Surfaces.make_galvanised_steel()
		rail_mesh = BoxMesh.new()

	for i: int in SEGMENTS:
		var a: Dictionary = _sample(i)
		var b: Dictionary = _sample(i + 1)
		var a_pos: Vector3 = a["position"]
		var b_pos: Vector3 = b["position"]

		# Carrefour en X : aucune glissière, les deux boucles s'y croisent.
		if _in_junction(a_pos) or _in_junction(b_pos):
			continue

		for sign_side: float in [-1.0, 1.0]:
			var from: Vector3 = a_pos + a["side"] * sign_side * RAIL_OFFSET
			var to: Vector3 = b_pos + b["side"] * sign_side * RAIL_OFFSET
			var mid: Vector3 = (from + to) * 0.5
			var span: Vector3 = to - from
			var seg_length: float = span.length()
			if seg_length < 0.01:
				continue

			var shape: CollisionShape3D = CollisionShape3D.new()
			var box: BoxShape3D = BoxShape3D.new()
			box.size = Vector3(0.25, RAIL_HEIGHT, seg_length + 0.15)
			shape.shape = box
			shape.position = mid + Vector3(0.0, RAIL_HEIGHT * 0.5, 0.0)
			shape.rotation.y = atan2(span.x, span.z)
			rails.add_child(shape)

			if _headless:
				continue
			# Deux lisses visibles (haute et basse) pour la double glissière.
			for rail_y: float in [0.45, 1.15]:
				var beam: MeshInstance3D = MeshInstance3D.new()
				beam.mesh = rail_mesh
				beam.material_override = mat_rail
				beam.scale = Vector3(0.2, 0.28, seg_length + 0.15)
				beam.position = mid + Vector3(0.0, rail_y, 0.0)
				beam.rotation.y = atan2(span.x, span.z)
				rails.add_child(beam)


func _in_junction(point: Vector3) -> bool:
	return Vector2(point.x, point.z).length() < JUNCTION_RADIUS


## Mâts de projecteurs de stade éclairant les virages et le croisement.
func _build_floodlights() -> void:
	var mast_positions: Array[Vector3] = [
		Vector3(0.0, 0.0, 34.0),      # carrefour, côté sud
		Vector3(0.0, 0.0, -34.0),     # carrefour, côté nord
		Vector3(58.0, 0.0, 30.0),     # boucle droite
		Vector3(58.0, 0.0, -30.0),
		Vector3(-58.0, 0.0, 30.0),    # boucle gauche
		Vector3(-58.0, 0.0, -30.0),
	]
	var aim_targets: Array[Vector3] = [
		Vector3.ZERO, Vector3.ZERO,
		Vector3(62.0, 0.0, 0.0), Vector3(62.0, 0.0, 0.0),
		Vector3(-62.0, 0.0, 0.0), Vector3(-62.0, 0.0, 0.0),
	]

	var mat_mast: StandardMaterial3D = StandardMaterial3D.new()
	mat_mast.albedo_color = Color(0.16, 0.16, 0.18)
	mat_mast.metallic = 0.6
	mat_mast.roughness = 0.5

	var holder: Node3D = Node3D.new()
	holder.name = "Floodlights"
	add_child(holder)

	for i: int in mast_positions.size():
		var base: Vector3 = mast_positions[i]
		var mast_height: float = 22.0

		var pole: MeshInstance3D = MeshInstance3D.new()
		var pole_mesh: CylinderMesh = CylinderMesh.new()
		pole_mesh.top_radius = 0.28
		pole_mesh.bottom_radius = 0.45
		pole_mesh.height = mast_height
		pole.mesh = pole_mesh
		pole.material_override = mat_mast
		pole.position = base + Vector3(0.0, mast_height * 0.5, 0.0)
		holder.add_child(pole)

		var head: Vector3 = base + Vector3(0.0, mast_height, 0.0)
		var lamp: SpotLight3D = SpotLight3D.new()
		lamp.position = head
		# Les deux premiers mâts éclairent le CARREFOUR, là où se jouent les
		# T-Bones : portée et ombres pleines. Les quatre mâts de boucle sont
		# limités en portée — six shadow maps à 90 m coûteraient inutilement cher.
		var is_junction_mast: bool = i < 2
		lamp.spot_range = 95.0 if is_junction_mast else 70.0
		lamp.spot_angle = 52.0
		lamp.spot_attenuation = 0.85
		lamp.light_energy = 9.0 if is_junction_mast else 7.0
		lamp.light_color = Color(1.0, 0.94, 0.82)
		lamp.shadow_enabled = true
		lamp.shadow_bias = 0.05
		lamp.shadow_normal_bias = 1.2
		holder.add_child(lamp)
		# look_at exige d'être dans l'arbre et une cible non colinéaire.
		lamp.look_at(aim_targets[i], Vector3.UP)

		var housing: MeshInstance3D = MeshInstance3D.new()
		var housing_mesh: BoxMesh = BoxMesh.new()
		housing_mesh.size = Vector3(3.2, 1.0, 0.5)
		housing.mesh = housing_mesh
		housing.material_override = mat_mast
		housing.position = head
		holder.add_child(housing)
