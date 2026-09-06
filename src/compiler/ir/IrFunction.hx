package compiler.ir;

import compiler.ir.Ir;

/** Verified SSA function with explicit arguments, blocks, and result type. */
class IrFunction {
	public final name:String;
	public final arguments:Array<IrValue>;
	public final result:IrType;
	public final blocks:Array<IrBlock>;

	public function new(name, arguments, result, blocks) {
		this.name = name;
		this.arguments = arguments;
		this.result = result;
		this.blocks = blocks;
	}
}
