package compiler.ir;

/**
 * A value of an `IrBody`, by id: dense within its body and never reused, so it indexes the body's value columns and a pass's
 * tables. Made from an `Int` only explicitly (`of`), so a row or block number cannot pass for one.
 */
abstract IrValueId(Int) to Int {
	inline function new(id:Int)
		this = id;

	public static inline function of(id:Int):IrValueId
		return new IrValueId(id);

	/** Whether this names a value: the output of a row that defines none does not. */
	public inline function exists():Bool
		return this >= 0;
}
