package compiler.ir;

import compiler.ir.Ir;

/** Exact post-inline arithmetic rewrites. */
class IrStrengthReduction {
	/**
	 * On a body, in place: a float division by a constant whose reciprocal is exact (`exactNormalReciprocal`) becomes a
	 * multiplication by that reciprocal.
	 */
	public static function runBody(body:IrBody):Bool {
		var f64 = body.typeId(F64), changed = false;
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				var next = body.nextRow(row);
				if (body.opcode(row) == IrOpcode.Div && body.valueTypeId(body.output(row)) == f64
					&& body.valueTypeId(body.operand(row, 1)) == f64) {
					var divisor = body.definingRow(body.operand(row, 1));
					if (divisor >= 0 && body.opcode(divisor) == IrOpcode.ConstFloat
						&& exactNormalReciprocal(body.float(divisor))) {
						var where = body.provenance(row),
							reciprocal = body.newValue("strength.reciprocal", f64);
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
