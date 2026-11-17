package compiler.ir;

import compiler.ir.Ir;
import compiler.ir.SourceProvenance.Located;

/**
 * Removes what a rewrite of a function's edges left unreachable: the blocks its entry no longer reaches, the phi inputs from
 * blocks that no longer flow into the phi's block, and the debug bindings of values only removed blocks defined. Reachability
 * counts a try region's handler and its after block as reached from where the region begins, and the handler from where it ends,
 * so a rewrite never removes a handler some reached block installs.
 */
class IrUnreachableBlocks {
	public static function remove(fn:IrFunction):IrFunction {
		var successors:Map<Int, Array<Int>> = [];
		for (block in fn.blocks)
			successors.set(block.id, edges(block));
		var reached:Map<Int, Bool> = [fn.blocks[0].id => true], work = [fn.blocks[0].id];
		while (work.length > 0) {
			var next = successors.get(work.pop());
			if (next != null)
				for (target in next)
					if (!reached.exists(target)) {
						reached.set(target, true);
						work.push(target);
					}
		}
		var changed = false;
		for (block in fn.blocks)
			if (!reached.exists(block.id))
				changed = true;
			else
				for (located in block.instructions)
					switch located.value {
						case Phi(_, inputs):
							for (input in inputs)
								if (!flows(input.block, block.id, successors, reached))
									changed = true;
						default:
					}
		if (!changed)
			return fn;
		var blocks:Array<IrBlock> = [], removedValues:Map<Int, Bool> = [];
		for (block in fn.blocks) {
			if (!reached.exists(block.id)) {
				for (located in block.instructions) {
					var output = IrOperands.output(located.value);
					if (output != null)
						removedValues.set(output.id, true);
				}
				continue;
			}
			var instructions = block.instructions.copy();
			for (index in 0...instructions.length)
				switch instructions[index].value {
					case Phi(output, inputs):
						var kept = [for (input in inputs) if (flows(input.block, block.id, successors, reached)) input];
						if (kept.length != inputs.length)
							instructions[index] = new Located(Phi(output, kept), instructions[index].provenance);
					default:
				}
			var copy = new IrBlock(block.id, instructions);
			copy.terminator = block.terminator;
			blocks.push(copy);
		}
		return fn.withBlocks(blocks,
			[for (binding in fn.debugBindings) if (!removedValues.exists(binding.value.id)) binding]);
	}

	/** Whether control still flows from `from` into `to`: `from` is reached and one of its edges leads there. */
	static function flows(from:Int, to:Int, successors:Map<Int, Array<Int>>, reached:Map<Int, Bool>):Bool {
		var next = successors.get(from);
		return reached.exists(from) && next != null && next.indexOf(to) >= 0;
	}

	/** The blocks `block` can transfer to: its terminator's targets, and the handlers and after blocks of the try regions in it. */
	static function edges(block:IrBlock):Array<Int> {
		var result:Array<Int> = [];
		for (located in block.instructions)
			switch located.value {
				case BeginTry(catchBlock, afterBlock, _):
					result.push(catchBlock);
					result.push(afterBlock);
				case EndTry(catchBlock, _):
					result.push(catchBlock);
				default:
			}
		if (block.terminator != null)
			switch block.terminator.value {
				case Jump(target):
					result.push(target);
				case Branch(_, whenTrue, whenFalse):
					result.push(whenTrue);
					result.push(whenFalse);
				case Switch(_, targets, otherwise):
					for (target in IrSwitch.successors(targets, otherwise))
						result.push(target);
				case Return(_), Throw(_), Rethrow(_), Unreachable:
			}
		return result;
	}
}
