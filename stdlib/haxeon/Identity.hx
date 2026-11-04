package haxeon;

/** Compare class instances by reference, independently of declared value equality. */
class Identity {}

private extern class IdentityNative {
 @:hlNative("haxeon_runtime", "__reference_identity")
 public static function same(left:Dynamic, right:Dynamic):Bool;
}
