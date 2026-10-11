function main():Int {
	var rounded:Float32 = cast 1.00000005,
		one:Float32 = cast 1.0,
		widened:Float = cast rounded;
	return rounded == one && widened == 1.0 ? 42 : 1;
}
