extends Node

## Synthèse audio procédurale (autoload `SoundManager`).
##
## Aucun asset audio n'existe dans le projet : toutes les formes d'onde sont
## calculées au démarrage puis PARTAGÉES. Chaque véhicule instancie son propre
## AudioStreamPlayer3D pointant sur le même `AudioStreamWAV` et ne pilote que
## son `pitch_scale` / `volume_db` : synthétiser une boucle par voiture coûterait
## cinq fois plus de mémoire pour un résultat identique.
##
## Sur un serveur headless, rien n'est généré ni joué (`is_active()` renvoie
## false) : le serveur dédié ne doit pas brûler de CPU pour un son que personne
## n'entend.

const MIX_RATE: int = 22050

# --- Boucles partagées ---
var engine_stream: AudioStreamWAV = null
var tire_stream: AudioStreamWAV = null
# --- Coups uniques ---
var crash_stream: AudioStreamWAV = null
var impact_hi_stream: AudioStreamWAV = null
var impact_sub_stream: AudioStreamWAV = null
var backfire_stream: AudioStreamWAV = null

var _active: bool = false
var _drift_player: AudioStreamPlayer = null


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		return
	_build_streams()


## Regroupé pour que les tests puissent forcer la génération hors headless.
func _build_streams() -> void:
	engine_stream = _make_engine_loop()
	tire_stream = _make_tire_loop()
	crash_stream = _make_impact_transient()
	impact_hi_stream = crash_stream
	impact_sub_stream = _make_impact_sub()
	backfire_stream = _make_backfire()

	_drift_player = AudioStreamPlayer.new()
	_drift_player.stream = tire_stream
	_drift_player.volume_db = -12.0
	add_child(_drift_player)
	_active = true


func is_active() -> bool:
	return _active


# ---------------------------------------------------------------------------
# SYNTHÈSE
# ---------------------------------------------------------------------------

func _new_stream(loop: bool, sample_count: int) -> AudioStreamWAV:
	var stream: AudioStreamWAV = AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = MIX_RATE
	stream.stereo = false
	if loop:
		stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
		stream.loop_begin = 0
		stream.loop_end = sample_count
	return stream


func _encode(stream: AudioStreamWAV, samples: PackedFloat32Array) -> AudioStreamWAV:
	var bytes: PackedByteArray = PackedByteArray()
	bytes.resize(samples.size() * 2)
	for i: int in samples.size():
		bytes.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32000.0))
	stream.data = bytes
	return stream


## Moteur : dent de scie filtrée + bruit basse fréquence.
##
## La boucle fait un nombre ENTIER de périodes (50 Hz à 22050 Hz = 441
## échantillons pile), sans quoi le raccord produirait un clic à chaque tour.
func _make_engine_loop() -> AudioStreamWAV:
	var base_freq: float = 50.0
	var period: int = int(round(float(MIX_RATE) / base_freq))   # 441
	var periods: int = 20
	var count: int = period * periods

	var samples: PackedFloat32Array = PackedFloat32Array()
	samples.resize(count)

	var low_state: float = 0.0     # passe-bas 1 pôle : adoucit la dent de scie
	var noise_state: float = 0.0   # bruit "grondement" basse fréquence
	for i: int in count:
		var phase: float = float(i % period) / float(period)
		# Dent de scie + harmonique paire pour la texture V8.
		var saw: float = (phase * 2.0 - 1.0)
		var rumble: float = sin(TAU * 2.0 * phase) * 0.35
		var raw: float = saw * 0.55 + rumble

		noise_state = lerpf(noise_state, randf_range(-1.0, 1.0), 0.06)
		raw += noise_state * 0.22

		low_state = lerpf(low_state, raw, 0.35)
		samples[i] = low_state * 0.85
	return _encode(_new_stream(true, count), samples)


## Crissement : bruit blanc passé dans un passe-bande résonant (filtre à
## variable d'état), ce qui donne le sifflement de gomme plutôt qu'un souffle.
func _make_tire_loop() -> AudioStreamWAV:
	var count: int = int(0.5 * MIX_RATE)
	var samples: PackedFloat32Array = PackedFloat32Array()
	samples.resize(count)

	var cutoff: float = 1500.0
	var f: float = 2.0 * sin(PI * cutoff / float(MIX_RATE))
	var q: float = 0.22
	var low: float = 0.0
	var band: float = 0.0

	for i: int in count:
		var input: float = randf_range(-1.0, 1.0)
		low += f * band
		var high: float = input - low - q * band
		band += f * high
		samples[i] = clampf(band * 0.8, -1.0, 1.0)

	# Fondu enchaîné sur le raccord de boucle pour supprimer le clic.
	var fade: int = 256
	for i: int in fade:
		var t: float = float(i) / float(fade)
		samples[i] = lerpf(samples[count - fade + i], samples[i], t)
	return _encode(_new_stream(true, count), samples)


## Transitoire d'impact métallique : sinus inharmoniques + bruit, décroissance
## très rapide. C'est la couche AIGUË du choc.
func _make_impact_transient() -> AudioStreamWAV:
	var count: int = int(0.45 * MIX_RATE)
	var samples: PackedFloat32Array = PackedFloat32Array()
	samples.resize(count)
	var partials: PackedFloat32Array = PackedFloat32Array([523.0, 787.0, 1310.0, 2090.0])
	for i: int in count:
		var t: float = float(i) / float(MIX_RATE)
		var env: float = exp(-t * 16.0)
		var value: float = 0.0
		for k: int in partials.size():
			value += sin(TAU * partials[k] * t) * (0.5 / float(k + 1))
		value += randf_range(-1.0, 1.0) * 0.55 * exp(-t * 42.0)
		samples[i] = value * env * 0.9
	return _encode(_new_stream(false, count), samples)


## Couche SUB (40-60 Hz) : donne le poids physique. Le sinus descend de 58 à
## 40 Hz pendant la décroissance, ce qui s'entend comme un « thud » et non
## comme une note.
func _make_impact_sub() -> AudioStreamWAV:
	var count: int = int(0.6 * MIX_RATE)
	var samples: PackedFloat32Array = PackedFloat32Array()
	samples.resize(count)
	var phase: float = 0.0
	for i: int in count:
		var t: float = float(i) / float(MIX_RATE)
		var freq: float = lerpf(58.0, 40.0, clampf(t / 0.6, 0.0, 1.0))
		phase += TAU * freq / float(MIX_RATE)
		var env: float = exp(-t * 5.5)
		samples[i] = sin(phase) * env
	return _encode(_new_stream(false, count), samples)


## Détonation d'échappement : claquement bref, bruit filtré + pointe grave.
func _make_backfire() -> AudioStreamWAV:
	var count: int = int(0.3 * MIX_RATE)
	var samples: PackedFloat32Array = PackedFloat32Array()
	samples.resize(count)
	var low: float = 0.0
	for i: int in count:
		var t: float = float(i) / float(MIX_RATE)
		var env: float = exp(-t * 26.0)
		low = lerpf(low, randf_range(-1.0, 1.0), 0.5)
		var thump: float = sin(TAU * lerpf(150.0, 70.0, clampf(t / 0.3, 0.0, 1.0)) * t)
		samples[i] = (low * 0.75 + thump * 0.6) * env
	return _encode(_new_stream(false, count), samples)


# ---------------------------------------------------------------------------
# LECTURE
# ---------------------------------------------------------------------------

## Crée un lecteur 3D en boucle attaché à `parent` (moteur ou pneus).
func make_loop_player(parent: Node3D, stream: AudioStreamWAV, volume_db: float,
		max_distance: float) -> AudioStreamPlayer3D:
	if not _active or not stream or not parent:
		return null
	var player: AudioStreamPlayer3D = AudioStreamPlayer3D.new()
	player.stream = stream
	player.volume_db = volume_db
	player.max_distance = max_distance
	player.unit_size = 6.0
	parent.add_child(player)
	player.play()
	return player


## Coup unique positionné dans le monde, auto-détruit à la fin.
func play_one_shot_3d(stream: AudioStreamWAV, where: Vector3, volume_db: float,
		pitch: float = 1.0) -> void:
	if not _active or not stream:
		return
	var scene: Node = get_tree().current_scene
	if not scene:
		return
	var player: AudioStreamPlayer3D = AudioStreamPlayer3D.new()
	player.stream = stream
	player.volume_db = volume_db
	player.pitch_scale = pitch
	player.max_distance = 120.0
	player.unit_size = 10.0
	player.position = where
	scene.add_child(player)
	player.play()
	player.finished.connect(player.queue_free)


## Impact à DEUX COUCHES : transitoire métallique + sub 40-60 Hz.
func play_impact(where: Vector3, strength: float) -> void:
	if not _active:
		return
	var amount: float = clampf(strength, 0.0, 1.0)
	play_one_shot_3d(impact_hi_stream, where, lerpf(-14.0, 3.0, amount),
		randf_range(0.85, 1.25))
	# Le sub ne se déclenche que sur un vrai choc : l'ajouter aux frottements
	# transformerait un contact de peloton en bourdon continu.
	if amount > 0.35:
		play_one_shot_3d(impact_sub_stream, where, lerpf(-8.0, 5.0, amount), 1.0)


func play_backfire(where: Vector3) -> void:
	play_one_shot_3d(backfire_stream, where, -6.0, randf_range(0.9, 1.15))


# --- Compatibilité : points d'entrée historiques encore appelés ---------------

func play_crash_sound() -> void:
	if not _active:
		return
	var player: AudioStreamPlayer = AudioStreamPlayer.new()
	player.stream = crash_stream
	player.pitch_scale = randf_range(0.85, 1.25)
	player.volume_db = 0.0
	add_child(player)
	player.play()
	player.finished.connect(player.queue_free)


func play_drift_sound() -> void:
	if _active and _drift_player and not _drift_player.playing:
		_drift_player.play()


func stop_drift_sound() -> void:
	if _active and _drift_player and _drift_player.playing:
		_drift_player.stop()
