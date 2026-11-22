package compiler.ir.names;

/** Target-independent null check for a receiver whose method call is lowered or inlined. */
class IrReceiverCheck {
	public static inline final NAME = "$receiver:check";

	/** A pseudo-field lowered as a null check on the holder, with no actual storage slot. */
	public static inline final CHECK_FIELD = "$wasm-gc:check-holder";

	/** `String.length`, a runtime call that reads its string as a field read does: it checks the string as a receiver. */
	public static inline final STRING_LENGTH = "__string_length";
}
