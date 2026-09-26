package runtime;

/**
 * Low-level immutable module data provided by the Wasm backends. wasm32 places the data in
 * linear memory; Wasm GC keeps it in an immutable i32 array, so `loadI32` addresses must be
 * 4-byte aligned offsets derived from `address`.
 */
extern class RuntimeData {
	@:hlNative("haxeon_runtime", "__runtime_data_address")
	public static function address(hexChunks:Array<String>):Int;

	/** Read the little-endian 32-bit word at an address inside data returned by `address`. */
	@:hlNative("haxeon_runtime", "__wasm_memory_load_i32")
	public static function loadI32(address:Int):Int;

	/** Create a managed string by copying an ASCII range from an integer array. */
	@:hlNative("haxeon_runtime", "__runtime_string_from_ascii")
	public static function stringFromAscii(chars:Array<Int>, offset:Int, length:Int):String;
}
