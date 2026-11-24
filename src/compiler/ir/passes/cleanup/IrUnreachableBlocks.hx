package compiler.ir.passes.cleanup;

import compiler.ir.cfg.IrSwitch;
import compiler.ir.model.IrBody;
import compiler.ir.model.IrFunction;
import compiler.ir.model.IrOpcode;
import compiler.ir.model.IrOperands;
import compiler.ir.model.IrPassScratch;

import compiler.ir.model.Ir;
import compiler.ir.model.SourceProvenance.Located;

/**
 * Removes what a rewrite of a function's edges left unreachable: the blocks its entry no longer reaches, the phi inputs from
 * blocks that no longer flow into the phi's block, and the debug bindings of values only removed blocks defined. Reachability
 * counts a try region's handler and its after block as reached from where the region begins, and the handler from where it ends,
 * so a rewrite never removes a handler some reached block installs.
 */
@:nullSafety(Strict)
class IrUnreachableBlocks {
	public static function remove(fn:IrFunction):IrFunction {
		var successors:Map<Int, Array<Int>> = [];
		for (block in fn.blocks)
			successors.set(block.id, edges(block));
		var reached:Map<Int, Bool> = [fn.blocks[0].id => true], work = [fn.blocks[0].id];
		while (work.length > 0) {
			var id = work.pop();
			if (id == null)
				break;
			var next = successors.get(id);
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
			// The instructions are copied only when a phi loses an input; any other reached block is shared as it is.
			var instructions:Null<Array<Located<IrInstruction>>> = null;
			for (index in 0...block.instructions.length)
				switch block.instructions[index].value {
					case Phi(output, inputs):
						var kept = [for (input in inputs) if (flows(input.block, block.id, successors, reached)) input];
						if (kept.length != inputs.length) {
							if (instructions == null)
								instructions = block.instructions.copy();
							instructions[index] = new Located(Phi(output, kept), block.instructions[index].provenance);
						}
					default:
				}
			if (instructions == null) {
				blocks.push(block);
				continue;
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

	/** `remove` on a body, in place; whether it changed the body. */
	public static function removeBody(body:IrBody, scratch:IrPassScratch):Bool {
		var count = body.blockCount(), size = 0;
		for (block in 0...count)
			if (body.blockId(block) >= size)
				size = body.blockId(block) + 1;
		// By block id: its index (-1 for none), and whether the entry reaches it (1).
		var indices = IrPassScratch.filledInts(scratch.firstInts, size, -1),
			reached = IrPassScratch.filledInts(scratch.secondInts, size, 0),
			work = scratch.pendingIds,
			targets = scratch.blockList;
		for (block in 0...count)
			indices[body.blockId(block)] = block;
		work.resize(0);
		reached[body.blockId(0)] = 1;
		work.push(body.blockId(0));
		while (work.length > 0) {
			var id = work[work.length - 1];
			work.resize(work.length - 1);
			var block = id >= 0 && id < size ? indices[id] : -1;
			if (block < 0)
				continue;
			bodyEdges(body, block, targets);
			for (target in targets)
				if (target >= 0 && target < size && reached[target] == 0) {
					reached[target] = 1;
					work.push(target);
				}
		}
		inline function isReached(id:Int):Bool
			return id >= 0 && id < size && reached[id] == 1;
		function flows(from:Int, to:Int):Bool {
			if (!isReached(from) || indices[from] < 0)
				return false;
			bodyEdges(body, indices[from], targets);
			return targets.indexOf(to) >= 0;
		}
		var changed = false;
		for (block in 0...count) {
			var id = body.blockId(block);
			if (!isReached(id)) {
				changed = true;
				continue;
			}
			var row = body.firstRow(block);
			while (row >= 0) {
				if (body.opcode(row) == IrOpcode.Phi)
					for (index in 0...body.operandCount(row))
						if (!flows(body.auxInt(row, index), id))
							changed = true;
				row = body.nextRow(row);
			}
		}
		if (!changed)
			return false;
		// Phi inputs are decided against the edges as they are; then the blocks go.
		var removed = scratch.marked;
		removed.clear();
		for (block in 0...count) {
			var id = body.blockId(block), row = body.firstRow(block);
			while (row >= 0) {
				if (!isReached(id)) {
					if (body.output(row).exists())
						removed.add(body.output(row));
				} else if (body.opcode(row) == IrOpcode.Phi) {
					var index = body.operandCount(row) - 1;
					while (index >= 0) {
						if (!flows(body.auxInt(row, index), id))
							body.removePhiInput(row, index);
						index--;
					}
				}
				row = body.nextRow(row);
			}
		}
		var block = count - 1;
		while (block >= 0) {
			if (!isReached(body.blockId(block)))
				body.removeBlock(block);
			block--;
		}
		var index = body.bindingCount() - 1;
		while (index >= 0) {
			if (removed.has(body.bindingValue(index)))
				body.removeBinding(index);
			index--;
		}
		return true;
	}

	/** `edges` of a body's block (an index), into `targets`. */
	static function bodyEdges(body:IrBody, block:Int, targets:Array<Int>):Void {
		targets.resize(0);
		var row = body.firstRow(block);
		while (row >= 0) {
			switch body.opcode(row) {
				case IrOpcode.BeginTry:
					targets.push(body.auxInt(row, 0));
					targets.push(body.auxInt(row, 1));
				case IrOpcode.EndTry:
					targets.push(body.auxInt(row, 0));
				default:
					if (body.opcode(row).isTerminator())
						for (index in 0...body.successorCount(row))
							targets.push(body.successor(row, index));
			}
			row = body.nextRow(row);
		}
	}
}
