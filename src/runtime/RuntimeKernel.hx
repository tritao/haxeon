package runtime;

/**
	The deliberately small native bootstrap/kernel boundary for HashLink.

	Policy, module identity, patch compatibility, and generation ownership stay
	in Haxe. This class exposes only the opaque module operations that still need
	HashLink's native runtime and JIT machinery.
 */
@:hlNative("haxeon_runtime")
class RuntimeKernel {
	public static function load(bytes:hl.Bytes, length:Int, identity:hl.Bytes, identityLength:Int):RuntimeModuleHandle
		return null;

	public static function call_i32(module:RuntimeModuleHandle, index:Int):Int
		return 0;

	public static function call_void(module:RuntimeModuleHandle, index:Int):Void {}

	public static function call_bytes(module:RuntimeModuleHandle, index:Int):hl.Bytes
		return null;

	public static function call_bytes1(module:RuntimeModuleHandle, index:Int, argument:hl.Bytes):Void {}

	public static function call_closure(module:RuntimeModuleHandle, index:Int):Dynamic
		return null;

	public static function call_closure_i32(module:RuntimeModuleHandle, closure:Dynamic):Int
		return 0;

	public static function call_object(module:RuntimeModuleHandle, index:Int):Dynamic
		return null;

	public static function call_i32_object(module:RuntimeModuleHandle, index:Int, argument:Dynamic):Int
		return 0;

	public static function validate_call(module:RuntimeModuleHandle, index:Int, shape:Int):Int
		return -1;

	public static function type_count(module:RuntimeModuleHandle):Int
		return 0;

	public static function type_capacity(module:RuntimeModuleHandle):Int
		return 0;

	public static function live_allocation_count(module:RuntimeModuleHandle):Int
		return 0;

	public static function native_root_count(module:RuntimeModuleHandle):Int
		return 0;

	public static function retirement_status(module:RuntimeModuleHandle, out:hl.Bytes):Void {}

	public static function revision(module:RuntimeModuleHandle):Int
		return 0;

	public static function dispose(module:RuntimeModuleHandle):Int
		return -1;

	public static function retry_failed_retirements():Int
		return 0;

	public static function failed_retirement_count():Int
		return 0;

	public static function inspect_patch(bytes:hl.Bytes, length:Int):Int
		return -1;
}
