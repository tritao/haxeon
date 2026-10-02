// A boxed Int casts to Float and a boxed Float to Int, as on HashLink: JSON gives an Int box for a whole number.
function main():Int {
	var whole:Dynamic = 3;
	var fraction:Dynamic = 1.5;
	var asFloat:Float = cast whole;
	var exact:Float = cast fraction;
	var truncated:Int = cast fraction;
	return Std.int(asFloat * 10 + exact * 4) + truncated + 5;
}
