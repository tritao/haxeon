package compiler.ir.names;

/** Identity of managed object references, independently of any value comparison hook. */
class IrReferenceIdentity {
	public static inline final NAME = "$reference:same";

	@:processWide("the symbol of NAME, interned once: a name always denotes the same symbol")
	static var symbolId = -1;

	/** The id of NAME's symbol (`IrSymbol.of`), looked up once: passes ask for it per function. */
	public static function symbol():Int {
		if (symbolId < 0)
			symbolId = compiler.ir.model.IrSymbol.of(NAME).id;
		return symbolId;
	}
}
