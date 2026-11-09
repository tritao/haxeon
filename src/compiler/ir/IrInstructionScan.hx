package compiler.ir;

import compiler.ir.Ir.IrInstruction;

/**
 * A read-only look at a function's instructions, allocating nothing. Passes that rebuild a function's blocks use it to skip the
 * functions they cannot change: building new blocks and instruction arrays for every function costs about a hundred objects each,
 * whatever the pass finds.
 */
class IrInstructionScan {
	/** HAXEON_CHECK_REUSE=1: passes run on the functions they would skip and fail if one of them changes. */
	public static final checking = Sys.getEnv("HAXEON_CHECK_REUSE") == "1";

	public static function any(fn:IrFunction, test:IrInstruction->Bool):Bool {
		for (block in fn.blocks)
			for (located in block.instructions)
				if (test(located.value))
					return true;
		return false;
	}
}
