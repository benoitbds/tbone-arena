extends MeshInstance3D

func _ready() -> void:
	# Duplicate the material override to prevent all skidmarks from fading together
	if material_override:
		material_override = material_override.duplicate()
		
	var mat: StandardMaterial3D = material_override as StandardMaterial3D
	if mat:
		var tween: Tween = create_tween()
		# Remain solid for 2.0 seconds, then fade out during the last 1.0 second
		tween.tween_interval(2.0)
		tween.tween_property(mat, "albedo_color:a", 0.0, 1.0)
		tween.tween_callback(queue_free)
	else:
		# Fallback if no material is override
		get_tree().create_timer(3.0).timeout.connect(queue_free)
