package compiler.ir;

import compiler.ir.Ir;

/** Source local name associated with an SSA value after mutable stores vanish. */
typedef IrDebugBinding = {final name:String; final value:IrValue;}

/** Verified SSA function with explicit arguments, blocks, and result type. */
class IrFunction {
	public final name:String;
	public final arguments:Array<IrValue>;
	public final result:IrType;
	public final blocks:Array<IrBlock>;
	public final debugBindings:Array<IrDebugBinding>;

	public function new(name, arguments, result, blocks, ?debugBindings) {
		this.name = name;
		this.arguments = arguments;
		this.result = result;
		this.blocks = blocks;
		this.debugBindings = debugBindings == null ? [] : debugBindings;
	}
}
