enum Color {
	Red;
	Green;
	Blue;
}

enum Shape {
	Dot;
	Circle(radius:Int);
}

// Equality where the compiler only knows a value as Dynamic, as Haxe defines it.
function main():Int {
	var green:Dynamic = Green, otherGreen:Dynamic = Green, red:Dynamic = Red;
	var circle:Dynamic = Circle(1), otherCircle:Dynamic = Circle(1);
	var two:Dynamic = 2,
		twoFloat:Dynamic = 2.0,
		threeFloat:Dynamic = 3.0,
		half:Dynamic = 0.5;
	var mixed:Array<Dynamic> = [Red, Green, Blue];
	var checks = [
		// Constructors without arguments are one value; others are separate objects.
		green == otherGreen
		&& green != red,
		circle != otherCircle
		&& circle == circle,
		mixed.indexOf(Green) == 1
		&& mixed.contains(Blue)
		&& mixed.indexOf(Dot) == -1,
		mixed.remove(Red)
		&& mixed.length == 2
		&& !mixed.contains(Red),
		// A Dynamic Int equals a Dynamic Float of the same value.
		two == twoFloat
		&& twoFloat == two
		&& two != threeFloat
		&& threeFloat != two
		&& half != two];
	for (index in 0...checks.length)
		if (!checks[index])
			return index + 1;
	return 42;
}
