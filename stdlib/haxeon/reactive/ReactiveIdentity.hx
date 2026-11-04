package haxeon.reactive;

/** Reference identity for object ownership. */
extern class ReactiveIdentity {
	@:hlNative("haxeon_runtime", "__reference_identity")
	public static function same(left:Dynamic, right:Dynamic):Bool;
}
