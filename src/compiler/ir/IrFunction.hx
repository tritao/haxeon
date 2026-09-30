package compiler.ir;

import compiler.ir.Ir;

/** Source binding identity, lexical range, and SSA value after mutable stores vanish. */
typedef IrDebugBinding = {
	final identity:String;
	final name:String;
	final value:IrValue;
	final path:String;
	final scopeStart:Int;
	final scopeEnd:Int;
}

/** Verified SSA function with explicit arguments, blocks, and result type. */
class IrFunction {
	public final name:String;
	public final arguments:Array<IrValue>;
	public final result:IrType;
	public final blocks:Array<IrBlock>;
	public final debugBindings:Array<IrDebugBinding>;

	/** Declared `inline` in source; the inliner allows a larger body for such a function. */
	public final inlineHint:Bool;

	public function new(name, arguments, result, blocks, ?debugBindings, inlineHint = false) {
		this.name = name;
		this.arguments = arguments;
		this.result = result;
		this.blocks = blocks;
		this.debugBindings = debugBindings == null ? [] : debugBindings;
		this.inlineHint = inlineHint;
	}
}
