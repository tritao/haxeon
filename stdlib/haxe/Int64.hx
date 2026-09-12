package haxe;

/** Native signed 64-bit integer operations for Haxeon targets. */
extern class Int64 {
	@:hlNative("haxeon_runtime", "__int64_parse")
	public static function parseString(value:String):haxe.Int64;

	@:hlNative("haxeon_runtime", "__int64_to_string")
	public static function toStr(value:haxe.Int64):String;

	@:hlNative("haxeon_runtime", "__int64_of_int")
	public static function ofInt(value:Int):haxe.Int64;

	@:hlNative("haxeon_runtime", "__int64_from_float")
	public static function fromFloat(value:Float):haxe.Int64;

	@:hlNative("haxeon_runtime", "__int64_make")
	public static function make(high:Int, low:Int):haxe.Int64;

	@:hlNative("haxeon_runtime", "__int64_add")
	public static function add(left:haxe.Int64, right:haxe.Int64):haxe.Int64;

	@:hlNative("haxeon_runtime", "__int64_sub")
	public static function sub(left:haxe.Int64, right:haxe.Int64):haxe.Int64;

	@:hlNative("haxeon_runtime", "__int64_compare")
	public static function compare(left:haxe.Int64, right:haxe.Int64):Int;

	@:hlNative("haxeon_runtime", "__int64_unsigned_compare")
	public static function ucompare(left:haxe.Int64, right:haxe.Int64):Int;
}
