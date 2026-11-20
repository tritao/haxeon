package compiler.ir;

import compiler.ir.Ir;

/** Remove receiver checks only when a shared must-analysis proves the receiver non-null. */
class IrReceiverCheckElision {
	/** `scratch` is the caller's, reused across functions (`IrPassScratch`). */
	public static function run(fn:IrFunction, ?scratch:IrPassScratch):IrFunction {
		// Most functions have no receiver check: find that out before collecting every use.
		var hasCheck = false;
		for (block in fn.blocks) {
			for (located in block.instructions)
				switch located.value {
					case Call(_, name, _) if (name.name == IrReceiverCheck.NAME): hasCheck = true;
					default:
				}
			if (hasCheck)
				break;
		}
		if (!hasCheck)
			return fn;
		var tables = scratch ?? new IrPassScratch(), uses = tables.marked;
		uses.clear();
		for (block in fn.blocks) {
			for (located in block.instructions) {
				for (operand in 0...IrOperands.count(located.value)) uses.add(IrOperands.at(located.value, operand).id);
				switch located.value {
					case Phi(_, inputs): for (input in inputs) uses.add(input.value.id);
					default:
				}
			}
			if (block.terminator != null) switch block.terminator.value {
				case Return(value), Throw(value), Rethrow(value), Branch(value, _, _),
					Switch(value, _, _): uses.add(value.id);
				case Jump(_), Unreachable:
			}
		}
		for (binding in fn.debugBindings) uses.add(binding.value.id);
		var facts = new IrNonNullFacts(fn, false, null, tables.nonNull);
		return IrFunctionRewrite.dropInstructions(fn, function(block, index, located) {
			return switch located.value {
				case Call(output, name, arguments) if (name.name == IrReceiverCheck.NAME && arguments.length == 1):
					!uses.has(output.id) && facts.has(block.id, index);
				default: false;
			};
		});
	}
}
