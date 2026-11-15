package compiler.ir;

import compiler.ir.Ir.IrBlock;
import compiler.ir.Ir.IrInstruction;
import compiler.ir.SourceProvenance.Located;

/**
 * Copy-on-write rewriting of a function's instructions. A pass that does not know yet whether it will change a function gives this
 * helper its rule; the helper allocates nothing until the rule replaces an instruction, returns the very same `IrFunction` when it
 * never does, and otherwise copies only the blocks that changed and the function (unchanged blocks are shared with the original).
 * That is the "unchanged returns the same object" rule that a per-function cache and `IrInliner.stableSources` rely on.
 */
class IrFunctionRewrite {
	/**
	 * `replace` is asked about each instruction in order and returns null to keep it, or the instructions that take its place.
	 * Its side effects (helper requests, counters) happen exactly once per instruction, as in a hand-written loop.
	 */
	public static function instructions(fn:IrFunction, replace:Located<IrInstruction>->Null<Array<Located<IrInstruction>>>):IrFunction {
		var blocks:Null<Array<IrBlock>> = null;
		for (blockIndex in 0...fn.blocks.length) {
			var block = fn.blocks[blockIndex],
				list = block.instructions,
				rewritten:Null<Array<Located<IrInstruction>>> = null;
			for (index in 0...list.length) {
				var located = list[index], replacement = replace(located);
				if (replacement != null) {
					if (rewritten == null)
						rewritten = list.slice(0, index);
					for (instruction in replacement)
						rewritten.push(instruction);
				} else if (rewritten != null)
					rewritten.push(located);
			}
			if (rewritten == null) {
				if (blocks != null)
					blocks.push(block);
				continue;
			}
			if (blocks == null)
				blocks = fn.blocks.slice(0, blockIndex);
			var copy = new IrBlock(block.id, rewritten);
			copy.terminator = block.terminator;
			blocks.push(copy);
		}
		return blocks == null ? fn : fn.withBlocks(blocks);
	}

	/** The same rule for a pass that only removes instructions: `drop` is asked about each one with its block and index. */
	public static function dropInstructions(fn:IrFunction, drop:(block:IrBlock, index:Int, located:Located<IrInstruction>) -> Bool):IrFunction {
		var blocks:Null<Array<IrBlock>> = null;
		for (blockIndex in 0...fn.blocks.length) {
			var block = fn.blocks[blockIndex],
				list = block.instructions,
				kept:Null<Array<Located<IrInstruction>>> = null;
			for (index in 0...list.length) {
				var located = list[index];
				if (drop(block, index, located)) {
					if (kept == null)
						kept = list.slice(0, index);
				} else if (kept != null)
					kept.push(located);
			}
			if (kept == null) {
				if (blocks != null)
					blocks.push(block);
				continue;
			}
			if (blocks == null)
				blocks = fn.blocks.slice(0, blockIndex);
			var copy = new IrBlock(block.id, kept);
			copy.terminator = block.terminator;
			blocks.push(copy);
		}
		return blocks == null ? fn : fn.withBlocks(blocks);
	}
}
