package compiler.ir.gen;

import compiler.ir.model.Ir.IrBlock;

/** Active structured-loop targets and the trap depth at their declaration. */
typedef IrLoopContext = {
	final breakBlock:IrBlock;
	final continueBlock:IrBlock;
	final breakFlag:String;
	final trapDepth:Int;

	/** Set when a `break` of this loop is lowered; a loop that never breaks needs no break flag. */
	var breakUsed:Bool;
}
