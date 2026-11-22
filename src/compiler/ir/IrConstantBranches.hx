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
 * A function is rewritten only when a branch in it folds; the input functions are never changed. Per function
 * (`IrFunctionPass`): a function's summary is the constant it returns, and the rewrite reads, for each callee a branch
 * condition calls, the constant that callee returns (`CONSTANT`).
 */
class IrConstantBranches implements IrFunctionPass {
	/** The fact of a callee: 1 when it returns true, 0 false, -1 when it is not a constant function. */
	static inline final CONSTANT = 0;

	static inline final NOT_CONSTANT = -1;

	/** The functions whose whole body returns a Bool constant, with that constant (1 for true). */
	var constants:Map<String, Int> = [];

	public function new() {}

	public function summarize(fn:IrFunction):Int {
		if (fn.result != Bool || fn.blocks.length != 1)
			return NOT_CONSTANT;
		var block = fn.blocks[0], value:Null<Bool> = null, id = -1;
		if (block.instructions.length != 1 || block.terminator == null)
			return NOT_CONSTANT;
		switch block.instructions[0].value {
			case ConstBool(output, constant):
				value = constant;
				id = output.id;
			default:
		}
		if (value == null)
			return NOT_CONSTANT;
		return switch block.terminator.value {
			case Return(returned) if (returned.id == id): value ? 1 : 0;
			default: NOT_CONSTANT;
		}
	}

	public function prepare(functions:Array<IrFunction>, summaries:Array<Int>):Void {
		constants = [];
		for (index in 0...functions.length)
			if (summaries[index] != NOT_CONSTANT)
				constants.set(functions[index].name, summaries[index]);
	}

	public function fact(kind:Int, key:String):Int {
		var constant = constants.get(key);
		return constant == null ? NOT_CONSTANT : constant;
	}

	public function transform(fn:IrFunction, summary:Int, reader:IrFactReader):IrFunction
		return fold(fn, reader);

	public function request(type:IrType):Void {}

	public function finish(functions:Array<IrFunction>):Array<IrFunction>
		return functions;

	static function fold(fn:IrFunction, constants:IrFactReader):IrFunction {
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
					case Switch(value, cases, otherwise):
						// A switch on a constant made in its own block goes to the one block that constant selects.
						for (located in block.instructions)
							switch located.value {
								case ConstInt(output, constant) if (output.id == value.id):
									if (targets == null)
										targets = [];
									targets.set(block.id,
										constant >= 0 && constant < cases.length ? cases[constant] : otherwise);
								default:
							}
					default:
				}
		if (targets == null)
			return fn;
		// A folded branch jumps to the side it takes; what that leaves unreachable goes (IrUnreachableBlocks).
		var blocks:Array<IrBlock> = [];
		for (block in fn.blocks) {
			var target = targets.get(block.id), terminator = block.terminator;
			if (target == null || terminator == null) {
				blocks.push(block);
				continue;
			}
			var copy = new IrBlock(block.id, block.instructions);
			copy.terminator = new Located(Jump(target), terminator.provenance);
			blocks.push(copy);
		}
		return IrUnreachableBlocks.remove(fn.withBlocks(blocks));
	}

	/**
	 * What the value `id`, defined in `block`, is known to be: 1 for true, 0 for false, -1 when not known. A Bool constant, a
	 * call to a constant function, or an equality of two such values (`!x` as a value is `x == false`).
	 */
	static function knownValue(block:IrBlock, id:Int, constants:IrFactReader, depth:Int):Int {
		var index = block.instructions.length;
		while (index-- > 0)
			switch block.instructions[index].value {
				case ConstBool(output, value) if (output.id == id):
					return value ? 1 : 0;
				case Call(output, name, _) if (output.id == id):
					return constants.read(CONSTANT, name.name);
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

}
