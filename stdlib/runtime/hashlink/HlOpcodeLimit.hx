package runtime.hashlink;

/** HashLink opcode ABI constants that must not become fields in the C record. */
class HlOpcodeLimit {
	/** Number of valid HashLink opcodes; mirrors OLast in HashLink's opcodes.h. */
	public static inline var LAST_OPCODE:Int = 102;
}
