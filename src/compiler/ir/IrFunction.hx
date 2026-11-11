package compiler.ir;

import compiler.Provides;
import compiler.Provides.HelperRequest;
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

	/** The operation this function serves for a type when a generator made it as a helper, else `None`. */
	public final provides:Provides<TypeKey>;

	/** The helpers this function calls that no pass has made yet; the pass that makes them reads these, not the names of its calls. */
	public final requests:Array<HelperRequest<IrType>>;

	/** `provides` is required: a function made without saying what it serves does not compile. */
	public function new(name, arguments, result, blocks, provides:Provides<TypeKey>, requests:Array<HelperRequest<IrType>>, ?debugBindings, inlineHint = false, retention:IrRetention = Reachable) {
		this.name = name;
		this.arguments = arguments;
		this.result = result;
		this.blocks = blocks;
		this.provides = provides;
		this.requests = requests;
		this.debugBindings = debugBindings == null ? [] : debugBindings;
		this.inlineHint = inlineHint;
		this.retention = retention;
	}

	/**
	 * This function with other blocks (and so possibly other arguments and result), keeping everything else it carries. Under another
	 * name it is a copy, not the provider of the original, so it serves nothing.
	 */
	public function derive(blocks:Array<IrBlock>, ?arguments:Array<IrValue>, ?result:IrType, ?debugBindings:Array<IrDebugBinding>, ?name:String):IrFunction
		return new IrFunction(name == null ? this.name : name, arguments == null ? this.arguments : arguments, result == null ? this.result : result,
			blocks, name == null || name == this.name ? provides : None, requests, debugBindings == null ? this.debugBindings : debugBindings, inlineHint, retention);
}
