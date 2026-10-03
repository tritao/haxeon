package compiler.ir;

import compiler.ir.Ir;
import compiler.ir.IrFunction;
import compiler.ir.SourceProvenance.Located;

/** Exact post-inline arithmetic rewrites. */
class IrStrengthReduction {
	public static var enabled:Bool = Sys.getEnv("HAXEON_STRENGTH") != "0";

	public static function run(fn:IrFunction):IrFunction {
		var constants:Map<Int, Float> = [];
		var nextValue = 0;
		for (argument in fn.arguments)
			if (argument.id >= nextValue)
				nextValue = argument.id + 1;
		for (block in fn.blocks)
			for (located in block.instructions) {
				var output = IrOperands.output(located.value);
				if (output != null && output.id >= nextValue)
					nextValue = output.id + 1;
				switch located.value {
					case ConstFloat(out, value):
						constants.set(out.id, value);
					default:
				}
			}

		var changed = false, blocks:Array<IrBlock> = [];
		for (block in fn.blocks) {
			var copy = new IrBlock(block.id);
			for (located in block.instructions)
				switch located.value {
					case Div(out, left, right) if (out.type == F64 && right.type == F64):
						var divisor = constants.get(right.id);
						if (divisor != null && exactNormalReciprocal(divisor)) {
							var reciprocal = new IrValue(nextValue++, "strength.reciprocal", F64);
							copy.instructions.push(new Located(ConstFloat(reciprocal, 1.0 / divisor), located.provenance));
							copy.instructions.push(new Located(Mul(out, left, reciprocal), located.provenance));
							changed = true;
						} else
							copy.instructions.push(located);
					default:
						copy.instructions.push(located);
				}
			copy.terminator = block.terminator;
			blocks.push(copy);
		}
		return changed ? new IrFunction(fn.name, fn.arguments, fn.result, blocks, fn.debugBindings, fn.inlineHint, fn.retention) : fn;
	}

	/** A normal binary power of two whose reciprocal is also normal. */
	public static function exactNormalReciprocal(value:Float):Bool {
		var bits = haxe.io.Bytes.alloc(8);
		bits.setDouble(0, value);
		var low = bits.getInt32(0), high = bits.getInt32(4);
		var exponent = (high >>> 20) & 0x7ff;
		return exponent > 0 && exponent <= 2045 && (high & 0xfffff) == 0 && low == 0;
	}
}
