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

/** Whether a backend that drops uncalled functions must keep one, and whether it exports it to its host. */
enum abstract IrRetention(Int) from Int to Int {
	/** Kept only while something reaches it. */
	var Reachable = 0;

	/** Declared `@:keep`: kept even when nothing calls it. */
	var Keep = 1;

	/** Declared `@:expose`: kept and exported under its name so the host can call it. */
	var Expose = 2;
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

	public final retention:IrRetention;

	public function new(name, arguments, result, blocks, ?debugBindings, inlineHint = false, retention:IrRetention = Reachable) {
		this.name = name;
		this.arguments = arguments;
		this.result = result;
		this.blocks = blocks;
		this.debugBindings = debugBindings == null ? [] : debugBindings;
		this.inlineHint = inlineHint;
		this.retention = retention;
	}
}
