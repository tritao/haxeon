package compiler.runtime.wasm;

/** Names and offsets shared by generated Wasm code and its managed runtime. */
class WasmRuntimeContract {
	public static inline final ABI_VERSION:Int = 1;
	public static inline final ROOT_SECTION = "haxeon.gc.roots";
	public static inline final PATCH_SECTION = "haxeon.patch";
	public static inline final ENTRY_EXPORT = "main";
	public static inline final MEMORY_EXPORT = "memory";

	public static function runtimeImport(symbol:String):String
		return "haxeon." + symbol;
}
