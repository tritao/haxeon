package compiler.ir.cfg;

import compiler.ir.cfg.Cfg.CfgBlock;

/** Active structured-loop targets and the trap depth at their declaration. */
typedef CfgLoopContext = {
	final breakBlock:CfgBlock;
	final continueBlock:CfgBlock;
	final breakFlag:String;
	final trapDepth:Int;

	/** Set when a `break` of this loop is lowered; a loop that never breaks needs no break flag. */
	var breakUsed:Bool;
}
