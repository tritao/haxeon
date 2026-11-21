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

	/** `run` on a body, in place: a division by such a constant becomes a multiplication by its reciprocal. */
	public static function runBody(body:IrBody):Bool {
		var f64 = body.typeId(F64), changed = false, nextValue = -1;
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				var next = body.nextRow(row);
				if (body.opcode(row) == IrOpcode.Div && body.valueTypeId(body.output(row)) == f64
					&& body.valueTypeId(body.operand(row, 1)) == f64) {
					var divisor = body.definingRow(body.operand(row, 1));
					if (divisor >= 0 && body.opcode(divisor) == IrOpcode.ConstFloat
						&& exactNormalReciprocal(body.float(divisor))) {
						if (nextValue < 0)
							nextValue = body.presentValueLimit();
						var where = body.provenance(row),
							reciprocal = body.newValueAt(nextValue++, "strength.reciprocal", f64);
						body.beginRow();
						var constant = body.endRow(IrOpcode.ConstFloat, reciprocal,
							body.addFloat(1.0 / body.float(divisor)),
							where);
						body.linkBefore(block, row, constant);
						body.beginRow();
						body.pushOperand(body.operand(row, 0));
						body.pushOperand(reciprocal);
						var product = body.endRow(IrOpcode.Mul, body.output(row), 0, where);
						body.removeRow(block, row);
						body.linkBefore(block, next, product);
						changed = true;
					}
				}
				row = next;
			}
		}
		return changed;
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
