package compiler.ir.names;

/** Target-independent null check for a receiver whose method call is lowered or inlined. */
class IrReceiverCheck {
	public static inline final NAME = "$receiver:check";

	@:processWide("the symbol of NAME, interned once: a name always denotes the same symbol")
	static var symbolId = -1;

	/** The id of NAME's symbol (`IrSymbol.of`), looked up once: passes ask for it per function. */
	public static function symbol():Int {
		if (symbolId < 0)
			symbolId = compiler.ir.model.IrSymbol.of(NAME).id;
		return symbolId;
	}

	/** A pseudo-field lowered as a null check on the holder, with no actual storage slot. */
	public static inline final CHECK_FIELD = "$wasm-gc:check-holder";

	/** `String.length`, a runtime call that reads its string as a field read does: it checks the string as a receiver. */
	public static inline final STRING_LENGTH = "__string_length";

	/**
	 * Whether a call of `name` is an array runtime native that reads its first argument, the array, as a field read does: it
	 * checks the array as a receiver. An allocation has no array yet and a cast passes null through.
	 */
	public static function readsArray(name:String):Bool
		return StringTools.startsWith(name, "__array_") && !allocatesArray(name) && name != "__array_check_cast"
			&& compiler.ir.passes.enums.IrArrayRuntimeNatives.isStorage(name);

	/** Whether a call of `name` makes a new array, which is never null. */
	public static function allocatesArray(name:String):Bool
		return StringTools.startsWith(name, "__array_alloc_");
}
