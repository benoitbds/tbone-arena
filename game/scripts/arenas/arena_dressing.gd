extends Node3D

## Habillage PBR de l'arène derby, monté par code (client uniquement) :
##  - asphalte et glissières à textures procédurales,
##  - nappe de terre/gravier débordant l'enceinte,
##  - mâts d'éclairage de stade périphériques projetant des ombres nettes.
##
## Le circuit dispose déjà de ses six mâts via track_builder.gd ; l'arène en
## était dépourvue et ne recevait que la lune et les OmniLight d'angle.

const Surfaces = preload("res://scripts/tracks/surface_materials.gd")

const ARENA_HALF: float = 40.0
const TERRAIN_SIZE: Vector2 = Vector2(190.0, 190.0)
const MAST_HEIGHT: float = 20.0


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		return
	_build_terrain()
	_retexture_surfaces()
	_build_floodlight_masts()


func _build_terrain() -> void:
	var ground: MeshInstance3D = MeshInstance3D.new()
	ground.name = "Terrain"
	var mesh: PlaneMesh = PlaneMesh.new()
	mesh.size = TERRAIN_SIZE
	mesh.subdivide_width = 20
	mesh.subdivide_depth = 20
	ground.mesh = mesh
	ground.material_override = Surfaces.make_gravel(Color(0.07, 0.063, 0.054), 24.0)
	# Sous la dalle d'asphalte (dont la face supérieure est à Y = 0).
	ground.position = Vector3(0.0, -0.06, 0.0)
	add_child(ground)


## Remplace les matériaux plats de la scène par leurs équivalents PBR texturés.
func _retexture_surfaces() -> void:
	var arena: Node = get_parent()
	if not arena:
		return

	var floor_mesh: MeshInstance3D = arena.get_node_or_null("ArenaFloor/MeshInstance3D") as MeshInstance3D
	if floor_mesh:
		floor_mesh.material_override = Surfaces.make_asphalt(Color(0.115, 0.12, 0.135), 14.0)

	var steel: StandardMaterial3D = Surfaces.make_galvanised_steel()
	for side: String in ["RailNorth", "RailSouth", "RailWest", "RailEast"]:
		var rail: MeshInstance3D = arena.get_node_or_null(side + "/Rail") as MeshInstance3D
		if rail:
			rail.material_override = steel


## Quatre mâts en périphérie, orientés vers le centre de l'arène.
func _build_floodlight_masts() -> void:
	var mat_mast: StandardMaterial3D = StandardMaterial3D.new()
	mat_mast.albedo_color = Color(0.15, 0.15, 0.17)
	mat_mast.metallic = 0.65
	mat_mast.roughness = 0.45

	var offset: float = ARENA_HALF + 8.0
	var bases: Array[Vector3] = [
		Vector3(-offset, 0.0, -offset), Vector3(offset, 0.0, -offset),
		Vector3(-offset, 0.0, offset), Vector3(offset, 0.0, offset),
	]

	for base: Vector3 in bases:
		var pole: MeshInstance3D = MeshInstance3D.new()
		var pole_mesh: CylinderMesh = CylinderMesh.new()
		pole_mesh.top_radius = 0.26
		pole_mesh.bottom_radius = 0.42
		pole_mesh.height = MAST_HEIGHT
		pole.mesh = pole_mesh
		pole.material_override = mat_mast
		pole.position = base + Vector3(0.0, MAST_HEIGHT * 0.5, 0.0)
		add_child(pole)

		var head: Vector3 = base + Vector3(0.0, MAST_HEIGHT, 0.0)
		var housing: MeshInstance3D = MeshInstance3D.new()
		var housing_mesh: BoxMesh = BoxMesh.new()
		housing_mesh.size = Vector3(3.0, 0.9, 0.5)
		housing.mesh = housing_mesh
		housing.material_override = mat_mast
		housing.position = head
		add_child(housing)

		var lamp: SpotLight3D = SpotLight3D.new()
		lamp.position = head
		lamp.spot_range = 95.0
		lamp.spot_angle = 46.0
		lamp.spot_attenuation = 0.85
		lamp.light_energy = 7.5
		lamp.light_color = Color(1.0, 0.94, 0.83)
		# Ombres nettes : c'est ce qui donne le contact au sol des véhicules et
		# matérialise les cônes dans le brouillard volumétrique.
		lamp.shadow_enabled = true
		lamp.shadow_bias = 0.04
		add_child(lamp)
		# look_at exige d'être déjà dans l'arbre.
		lamp.look_at(Vector3.ZERO, Vector3.UP)
