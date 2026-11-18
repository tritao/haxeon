// A body-less `extern` method with @:hlNative is a native in a class or abstract that is not extern itself (Haxe on HashLink
// leaves such a method unimplemented). The native is Haxeon's runtime square root, which HashLink and both Wasm runtimes
// provide: HashLink's std math_sqrt has no Wasm counterpart.
class Natives {
	@:hlNative("haxeon_runtime", "__math_sqrt") public static extern function sqrt(value:Float):Float;
}

abstract Root(Float) from Float {
	public var value(get, never):Float;

	@:hlNative("haxeon_runtime", "__math_sqrt") static extern function nativeSqrt(value:Float):Float;

	function get_value():Float
		return nativeSqrt(this);
}

function main():Int {
	var root:Root = 81.0;
	return Natives.sqrt(16) == 4 && root.value == 9 ? 42 : 1;
}
