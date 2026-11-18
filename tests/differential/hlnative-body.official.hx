// @:hlNative on a function with a body binds the native, as Haxe does on HashLink: the body never runs. On a class's static
// method, a module-level function, an abstract's static and an abstract's instance method (the receiver is argument zero), and
// through a function value.
class Native {
	@:hlNative("std", "math_sqrt") public static function sqrt(value:Float):Float
		return -1;
}

@:hlNative("std", "math_abs") function abs(value:Float):Float
	return -2;

abstract Meters(Float) from Float to Float {
	@:hlNative("std", "math_floor") public static function floor(value:Float):Int
		return -3;

	@:hlNative("std", "math_sqrt") public function root():Float
		return -4;
}

class Main {
	static function main() {
		Sys.println(Native.sqrt(16));
		Sys.println(abs(-5.5));
		Sys.println(Meters.floor(2.7));
		var meters:Meters = 49;
		Sys.println(meters.root());
		var sqrt = Native.sqrt;
		Sys.println(sqrt(81));
	}
}
