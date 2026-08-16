extends Node

## Fabrique de matériaux PBR à textures PROCÉDURALES (aucun asset image).
##
## Les `NoiseTexture2D` sont générées sur un thread de travail : elles se
## remplissent après coup. C'est sans conséquence ici (le matériau est prêt, la
## texture arrive une frame plus tard) mais cela signifie qu'un contrôle par
## lecture de pixels renverrait un faux négatif — vérifier l'affectation, pas
## le contenu.
##
## Script utilitaire : jamais instancié, toutes les fonctions sont statiques.

## Bruit tuilable réutilisable.
static func make_noise(frequency: float, octaves: int, seed_value: int) -> FastNoiseLite:
	var noise: FastNoiseLite = FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.seed = seed_value
	noise.frequency = frequency
	noise.fractal_octaves = octaves
	return noise


static func make_noise_texture(frequency: float, octaves: int, seed_value: int,
		size: int, as_normal: bool, bump: float = 8.0) -> NoiseTexture2D:
	var texture: NoiseTexture2D = NoiseTexture2D.new()
	texture.noise = make_noise(frequency, octaves, seed_value)
	texture.width = size
	texture.height = size
	texture.seamless = true
	texture.as_normal_map = as_normal
	if as_normal:
		texture.bump_strength = bump
	return texture


## Asphalte : grain de bitume porté par une normal map et une carte de rugosité
## issues du même bruit, à des fréquences différentes.
static func make_asphalt(albedo: Color, uv_scale: float) -> StandardMaterial3D:
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.albedo_color = albedo
	material.roughness = 0.85
	material.metallic = 0.0
	material.metallic_specular = 0.22
	material.normal_enabled = true
	material.normal_texture = make_noise_texture(0.055, 4, 1337, 512, true, 6.5)
	material.normal_scale = 1.35
	material.roughness_texture = make_noise_texture(0.018, 3, 7331, 256, false)
	material.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
	material.uv1_scale = Vector3(uv_scale, uv_scale, 1.0)
	material.uv1_triplanar = true
	return material


## Terre / gravier hors piste : plus rugueux, relief plus marqué.
static func make_gravel(albedo: Color, uv_scale: float) -> StandardMaterial3D:
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.albedo_color = albedo
	material.roughness = 0.97
	material.metallic = 0.0
	material.metallic_specular = 0.1
	material.normal_enabled = true
	material.normal_texture = make_noise_texture(0.12, 5, 2024, 512, true, 14.0)
	material.normal_scale = 2.0
	material.roughness_texture = make_noise_texture(0.05, 3, 4048, 256, false)
	material.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
	material.uv1_scale = Vector3(uv_scale, uv_scale, 1.0)
	material.uv1_triplanar = true
	return material


## Vibreur usé : la teinte est assombrie par un bruit de salissure et le
## brillant baissé, pour éviter le rouge/blanc plastique.
static func make_kerb(base: Color, seed_value: int) -> StandardMaterial3D:
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.albedo_color = base.darkened(0.12)
	material.roughness = 0.68
	material.metallic = 0.05
	material.normal_enabled = true
	material.normal_texture = make_noise_texture(0.25, 3, seed_value, 128, true, 4.0)
	material.normal_scale = 0.7
	material.roughness_texture = make_noise_texture(0.4, 4, seed_value + 11, 128, false)
	material.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
	material.uv1_scale = Vector3(2.0, 2.0, 1.0)
	return material


## Acier galvanisé des glissières.
static func make_galvanised_steel() -> StandardMaterial3D:
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.albedo_color = Color(0.74, 0.76, 0.79)
	material.metallic = 0.92
	material.roughness = 0.26
	material.normal_enabled = true
	material.normal_texture = make_noise_texture(0.35, 3, 909, 128, true, 2.5)
	material.normal_scale = 0.45
	material.roughness_texture = make_noise_texture(0.15, 3, 313, 128, false)
	material.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
	return material
