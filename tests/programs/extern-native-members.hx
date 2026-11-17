// A body-less `extern` method with @:hlNative is a native in a class or abstract that is not extern itself (Haxe on HashLink
// leaves such a method unimplemented; its std binds natives on methods with bodies, which Haxeon rejects).
class Natives {
	@:hlNative("std", "math_sqrt") public static extern function sqrt(value:Float):Float;
}

abstract Root(Float) from Float {
	public var value(get, never):Float;

	@:hlNative("std", "math_sqrt") static extern function nativeSqrt(value:Float):Float;

	function get_value():Float
		return nativeSqrt(this);
}

function main():Int {
	var root:Root = 81.0;
	return Natives.sqrt(16) == 4 && root.value == 9 ? 42 : 1;
}
