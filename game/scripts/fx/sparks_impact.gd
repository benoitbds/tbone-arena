extends CPUParticles3D

func _ready() -> void:
	emitting = true
	# Automatically clean up the node after particles complete their life cycle
	get_tree().create_timer(lifetime + 0.1).timeout.connect(queue_free)
