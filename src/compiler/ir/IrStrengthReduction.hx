package compiler.ir;

import compiler.ir.Ir;
import compiler.ir.IrFunction;
import compiler.ir.SourceProvenance.Located;

/** Exact post-inline arithmetic rewrites. */
class IrStrengthReduction {

	public static function run(fn:IrFunction):IrFunction {
		var constants:Map<Int, Float> = [];
		var nextValue = fn.nextValueId();
		for (block in fn.blocks)
			for (located in block.instructions)
				switch located.value {
					case ConstFloat(out, value):
						constants.set(out.id, value);
					default:
				}

		// Only the blocks with a division to reduce are copied; a function without one comes back as it is.
		return IrFunctionRewrite.instructions(fn, function(located) {
			return switch located.value {
				case Div(out, left, right) if ((switch (out.type) {
					case F64: true;
					default: false;
				}) && (switch (right.type) {
					case F64: true;
					default: false;
				})): var divisor = constants.get(right.id);
				if (divisor != null && exactNormalReciprocal(divisor)) {
					var reciprocal = new IrValue(nextValue++, "strength.reciprocal", F64);
					[
						new Located(ConstFloat(reciprocal, 1.0 / divisor), located.provenance),
						new Located(Mul(out, left, reciprocal), located.provenance)
					];
				} else
					null;
				default:
					null;
			};
		});
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
