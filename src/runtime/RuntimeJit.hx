package runtime;

/**
	The native JIT boundary for the legacy HashLink host runtime.

	Patch policy and generation ownership stay in Haxe. These operations retain
	the opaque module handle because native HashLink still owns executable memory,
	JIT publication, and code-region diagnostics.
 */
@:hlNative("haxeon_runtime")
class RuntimeJit {
	public static function patch(module:RuntimeModuleHandle, bytes:hl.Bytes, length:Int):Int
		return -1;

	public static function allocation_count(module:RuntimeModuleHandle):Int
		return 0;

	public static function patch_jit_count(module:RuntimeModuleHandle):Int
		return 0;

	public static function jit_location(module:RuntimeModuleHandle, index:Int):hl.Bytes
		return null;

	public static function debug_region_count(module:RuntimeModuleHandle):Int
		return 0;

	public static function retired_allocation_count(module:RuntimeModuleHandle):Int
		return 0;

	public static function set_patch_failure_stage(module:RuntimeModuleHandle, stage:Int):Void {}
}
