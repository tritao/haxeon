package compiler.ir;

import compiler.ir.Ir;

/**
 * Every place a function mentions a type. A pass that rewrites types can leave a function alone, and return the very same
 * `IrFunction`, when no position holds a type it rewrites; retained functions keep their identity for the caches keyed by it.
 */
class IrTypePositions {
	public static function any(fn:IrFunction, rewritten:IrType->Bool):Bool {
		if (rewritten(fn.result))
			return true;
		for (argument in fn.arguments)
			if (rewritten(argument.type))
				return true;
		for (binding in fn.debugBindings)
			if (rewritten(binding.value.type))
				return true;
		for (block in fn.blocks) {
			for (located in block.instructions) {
				var output = IrOperands.output(located.value);
				if (output != null && rewritten(output.type))
					return true;
				for (input in IrOperands.inputs(located.value))
					if (rewritten(input.type))
						return true;
				switch located.value {
					case TypeValue(_, type) if (rewritten(type)):
						return true;
					case Phi(_, inputs):
						for (input in inputs)
							if (rewritten(input.value.type))
								return true;
					default:
				}
			}
			if (block.terminator != null)
				switch block.terminator.value {
					case Return(value), Throw(value), Rethrow(value), Branch(value, _, _) if (rewritten(value.type)):
						return true;
					default:
				}
		}
		return false;
	}
}
