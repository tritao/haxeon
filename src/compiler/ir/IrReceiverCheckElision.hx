package compiler.ir;

import compiler.ir.Ir;

/** Remove receiver checks only when a shared must-analysis proves the receiver non-null. */
class IrReceiverCheckElision {
	public static function run(fn:IrFunction):IrFunction {
		var uses:Map<Int, Bool> = [], hasCheck = false;
		for (block in fn.blocks) {
			for (located in block.instructions) {
				for (value in IrOperands.inputs(located.value)) uses.set(value.id, true);
				switch located.value {
					case Phi(_, inputs): for (input in inputs) uses.set(input.value.id, true);
					case Call(_, name, _) if (name == IrReceiverCheck.NAME): hasCheck = true;
					default:
				}
			}
			if (block.terminator != null) switch block.terminator.value {
				case Return(value), Throw(value), Rethrow(value), Branch(value, _, _): uses.set(value.id, true);
				case Jump(_):
			}
		}
		for (binding in fn.debugBindings) uses.set(binding.value.id, true);
		if (!hasCheck) return fn;
		var facts = new IrNonNullFacts(fn), changed = false, blocks:Array<IrBlock> = [];
		for (block in fn.blocks) {
			var copy = new IrBlock(block.id);
			for (index in 0...block.instructions.length) {
				var located = block.instructions[index];
				var drop = switch located.value {
					case Call(output, name, arguments) if (name == IrReceiverCheck.NAME && arguments.length == 1):
						!uses.exists(output.id) && facts.has(block.id, index);
					default: false;
				};
				if (drop) changed = true; else copy.instructions.push(located);
			}
			copy.terminator = block.terminator;
			blocks.push(copy);
		}
		return changed ? new IrFunction(fn.name, fn.arguments, fn.result, blocks, fn.debugBindings, fn.inlineHint, fn.retention) : fn;
	}
}
