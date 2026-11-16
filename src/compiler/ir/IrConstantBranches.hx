package compiler.ir;

import compiler.ir.Ir;
import compiler.ir.SourceProvenance.Located;

/**
 * Folds branches whose condition is known before anything walks the program: a Bool constant, a call to a function that
 * only returns a Bool constant (`InputFiles.isRecording()` on Wasm, `#if`-selected flags), or an equality of two known
 * Bools. The branch becomes a jump, the blocks only the other side reached are removed with the phi inputs and debug
 * bindings that named them, and the reachability walks after it never see the calls those blocks made, so a dead branch
 * no longer links its callees (or their imports and runtime needs) into the program.
 *
 * A function is rewritten only when a branch in it folds; the input functions are never changed.
 */
class IrConstantBranches {
	/** Replaces, in `functions`, each function in which a branch folds by its folded copy; the functions themselves are not changed. */
	public static function run(functions:Array<IrFunction>):Void {
		var constants = constantFunctions(functions);
		for (index in 0...functions.length) {
			var fn = functions[index], folded = fold(fn, constants);
			if (folded != fn)
				functions[index] = folded;
		}
	}

	/** The functions whose whole body returns a Bool constant, with that constant. */
	static function constantFunctions(functions:Array<IrFunction>):Map<String, Bool> {
		var result:Map<String, Bool> = [];
		for (fn in functions) {
			if (fn.blocks.length != 1 || fn.result != Bool)
				continue;
			var block = fn.blocks[0], value:Null<Bool> = null, id = -1;
			if (block.instructions.length != 1 || block.terminator == null)
				continue;
			switch block.instructions[0].value {
				case ConstBool(output, constant):
					value = constant;
					id = output.id;
				default:
			}
			if (value == null)
				continue;
			switch block.terminator.value {
				case Return(returned) if (returned.id == id):
					result.set(fn.name, value);
				default:
			}
		}
		return result;
	}

	static function fold(fn:IrFunction, constants:Map<String, Bool>):IrFunction {
		// A condition is computed in the block that branches on it, so each branch looks there for what defines it; nothing is
		// allocated until a branch folds.
		var targets:Null<Map<Int, Int>> = null;
		for (block in fn.blocks)
			if (block.terminator != null)
				switch block.terminator.value {
					case Branch(condition, whenTrue, whenFalse):
						var value = knownValue(block, condition.id, constants, 0);
						if (value != -1) {
							if (targets == null)
								targets = [];
							targets.set(block.id, value == 1 ? whenTrue : whenFalse);
						}
					default:
				}
		if (targets == null)
			return fn;
		var byId:Map<Int, IrBlock> = [for (block in fn.blocks) block.id => block];
		// The blocks the entry still reaches; handlers count as reached where a reached block installs them.
		var reached:Map<Int, Bool> = [fn.blocks[0].id => true],
			work = [fn.blocks[0].id];
		inline function visit(next:Int):Void
			if (!reached.exists(next)) {
				reached.set(next, true);
				work.push(next);
			}
		while (work.length > 0) {
			var id = work.pop(), block = byId.get(id);
			if (block == null)
				continue;
			for (located in block.instructions)
				switch located.value {
					case BeginTry(catchBlock, afterBlock, _):
						visit(catchBlock);
						visit(afterBlock);
					case EndTry(catchBlock, _):
						visit(catchBlock);
					default:
				}
			var folded = targets.get(id);
			if (folded != null)
				visit(folded);
			else if (block.terminator != null)
				switch block.terminator.value {
					case Jump(target):
						visit(target);
					case Branch(_, whenTrue, whenFalse):
						visit(whenTrue);
						visit(whenFalse);
					default:
				}
		}
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
						var kept = [
							for (input in inputs)
								if (hasEdge(input.block, block.id, byId, reached, targets)) input
						];
						if (kept.length != inputs.length)
							instructions[index] = new Located(Phi(output, kept), instructions[index].provenance);
					default:
				}
			var copy = new IrBlock(block.id, instructions),
				target = targets.get(block.id),
				terminator = block.terminator;
			copy.terminator = target == null
				|| terminator == null ? terminator : new Located(Jump(target), terminator.provenance);
			blocks.push(copy);
		}
		var bindings = [
			for (binding in fn.debugBindings)
				if (!removedValues.exists(binding.value.id)) binding
		];
		return fn.withBlocks(blocks, bindings);
	}

	/**
	 * What the value `id`, defined in `block`, is known to be: 1 for true, 0 for false, -1 when not known. A Bool constant, a
	 * call to a constant function, or an equality of two such values (`!x` as a value is `x == false`).
	 */
	static function knownValue(block:IrBlock, id:Int, constants:Map<String, Bool>, depth:Int):Int {
		var index = block.instructions.length;
		while (index-- > 0)
			switch block.instructions[index].value {
				case ConstBool(output, value) if (output.id == id):
					return value ? 1 : 0;
				case Call(output, name, _) if (output.id == id):
					return constants.exists(name) ? (constants.get(name) ? 1 : 0) : -1;
				case Equal(output, left, right) if (output.id == id):
					if (depth > 0 || left.type != Bool || right.type != Bool)
						return -1;
					var leftValue = knownValue(block, left.id, constants, depth + 1);
					if (leftValue == -1)
						return -1;
					var rightValue = knownValue(block, right.id, constants, depth + 1);
					return rightValue == -1 ? -1 : (leftValue == rightValue ? 1 : 0);
				default:
					var output = IrOperands.output(block.instructions[index].value);
					if (output != null && output.id == id)
						return -1;
			}
		return -1;
	}

	/** Whether control still flows from block `from` into block `to`: `from` is reached and one of its remaining edges leads there. */
	static function hasEdge(from:Int, to:Int, byId:Map<Int, IrBlock>, reached:Map<Int, Bool>,
			targets:Map<Int, Int>):Bool {
		var block = byId.get(from);
		if (block == null || !reached.exists(from))
			return false;
		for (located in block.instructions)
			switch located.value {
				case BeginTry(catchBlock, afterBlock, _) if (catchBlock == to || afterBlock == to):
					return true;
				case EndTry(catchBlock, _) if (catchBlock == to):
					return true;
				default:
			}
		var folded = targets.get(from);
		if (folded != null)
			return folded == to;
		if (block.terminator != null)
			switch block.terminator.value {
				case Jump(target):
					return target == to;
				case Branch(_, whenTrue, whenFalse):
					return whenTrue == to || whenFalse == to;
				default:
			}
		return false;
	}
}
