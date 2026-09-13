package runtime;

/** Low-level immutable data and linear-memory operations provided by the Wasm backend. */
extern class RuntimeData {
	@:hlNative("haxeon_runtime", "__runtime_data_address")
	public static function address(hexChunks:Array<String>):Int;

	@:hlNative("haxeon_runtime", "__wasm_memory_load_i32")
	public static function loadI32(address:Int):Int;
}
