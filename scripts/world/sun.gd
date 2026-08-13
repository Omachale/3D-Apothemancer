extends DirectionalLight3D

## Simplest possible day cycle: continuously spins the light around a fixed
## world axis, so its direction sweeps like a real sun arcing overhead and
## dipping below the horizon at night. No colour/intensity/shadow-distance
## animation — motion only. Not tied to any game-time system, just wall clock.

## How long one full rotation takes. 300 = a five-minute day.
@export_range(5.0, 600.0, 5.0) var day_length_seconds := 300.0


func _process(delta: float) -> void:
	global_rotate(Vector3.RIGHT, TAU / day_length_seconds * delta)
