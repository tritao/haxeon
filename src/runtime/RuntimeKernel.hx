package runtime;

/**
	The deliberately small native bootstrap/kernel boundary for HashLink.

	Policy, module identity, patch compatibility, and generation ownership stay
	in Haxe. This class exposes only the opaque module operations that still need
	HashLink's native runtime and JIT machinery.
 */
@:hlNative("haxeon_runtime")
class RuntimeKernel {
	public static function load(bytes:hl.Bytes, length:Int, identity:hl.Bytes, identityLength:Int):hl.Abstract<"realtime_module">
		return null;

	public static function call_i32(module:hl.Abstract<"realtime_module">, index:Int):Int
		return 0;

	public static function call_void(module:hl.Abstract<"realtime_module">, index:Int):Void {}

	public static function call_bytes(module:hl.Abstract<"realtime_module">, index:Int):hl.Bytes
		return null;

	public static function call_bytes1(module:hl.Abstract<"realtime_module">, index:Int, argument:hl.Bytes):Void {}

	public static function call_closure(module:hl.Abstract<"realtime_module">, index:Int):Dynamic
		return null;

	public static function call_closure_i32(module:hl.Abstract<"realtime_module">, closure:Dynamic):Int
		return 0;

	public static function call_object(module:hl.Abstract<"realtime_module">, index:Int):Dynamic
		return null;

	public static function call_i32_object(module:hl.Abstract<"realtime_module">, index:Int, argument:Dynamic):Int
		return 0;

	public static function validate_call(module:hl.Abstract<"realtime_module">, index:Int, shape:Int):Int
		return -1;

	public static function type_count(module:hl.Abstract<"realtime_module">):Int
		return 0;

	public static function type_capacity(module:hl.Abstract<"realtime_module">):Int
		return 0;

	public static function live_allocation_count(module:hl.Abstract<"realtime_module">):Int
		return 0;

	public static function native_root_count(module:hl.Abstract<"realtime_module">):Int
		return 0;

	public static function retirement_status(module:hl.Abstract<"realtime_module">, out:hl.Bytes):Void {}

	public static function revision(module:hl.Abstract<"realtime_module">):Int
		return 0;

	public static function dispose(module:hl.Abstract<"realtime_module">):Int
		return -1;

	public static function retry_failed_retirements():Int
		return 0;

	public static function failed_retirement_count():Int
		return 0;

	public static function inspect_patch(bytes:hl.Bytes, length:Int):Int
		return -1;
}
