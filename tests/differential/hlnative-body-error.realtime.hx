// The body of a function @:hlNative binds is typed, as Haxe types it, though it never runs: "String should be Float".
class Main {
	@:hlNative("std", "math_sqrt") static function sqrt(value:Float):Float
		return "none";

	static function main() {
		Sys.println(sqrt(4));
	}
}
