import compiler.ir.Ir;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import compiler.ir.IrStrengthReduction;
import compiler.ir.codec.IrFunctionStateCodec;
import haxe.io.FPHelper;

class StrengthReductionMain {
	static function expect(ok:Bool, message:String):Void {
		if (!ok)
			throw message;
	}

	static function build(divisor:Float, leftConstant:Bool = false):IrFunction {
		var builder = new IrBuilder(),
			x = builder.argument("x", F64),
			constant = builder.constFloat(divisor);
		var result = leftConstant ? builder.div(constant, x) : builder.div(x, constant);
		builder.returnValue(result);
		return new IrFunction("test", builder.arguments, F64, builder.blocks);
	}

	static function operations(fn:IrFunction):{divides:Int, multiplies:Int, reciprocal:Null<Float>} {
		var divides = 0, multiplies = 0, reciprocal:Null<Float> = null;
		for (block in fn.blocks)
			for (located in block.instructions)
				switch located.value {
					case Div(_, _, _):
						divides++;
					case Mul(_, _, right):
						multiplies++;
						for (candidate in block.instructions)
							switch candidate.value {
								case ConstFloat(out, value) if (out.id == right.id): reciprocal = value;
								default:
							}
					default:
				}
		return {divides: divides, multiplies: multiplies, reciprocal: reciprocal};
	}

	static function sameBits(a:Float, b:Float):Bool {
		var aa = FPHelper.doubleToI64(a), bb = FPHelper.doubleToI64(b);
		return aa.high == bb.high && aa.low == bb.low;
	}

	static function main():Void {
		for (divisor in [2.0, 0.5, 1024.0, -4.0, Math.pow(2, -1022), Math.pow(2, 1022)]) {
			var source = build(divisor),
				encoded = IrFunctionStateCodec.encode(source),
				result = IrStrengthReduction.run(source),
				ops = operations(result);
			expect(ops.divides == 0 && ops.multiplies == 1, "power of two must become multiply: " + divisor);
			expect(ops.reciprocal != null && sameBits(ops.reciprocal, 1.0 / divisor), "reciprocal bits: " + divisor);
			expect(encoded.compare(IrFunctionStateCodec.encode(source)) == 0, "input mutation: " + divisor);
			expect(IrStrengthReduction.run(result) == result, "identity after rewrite: " + divisor);
		}
		for (divisor in [
			0.0,
			-0.0,
			3.0,
			10.0,
			Math.NaN,
			Math.POSITIVE_INFINITY,
			Math.pow(2, -1023),
			Math.pow(2, 1023)
		]) {
			var source = build(divisor),
				result = IrStrengthReduction.run(source),
				ops = operations(result);
			expect(result == source && ops.divides == 1 && ops.multiplies == 0, "must retain divide: " + divisor);
		}
		var left = build(2.0, true);
		expect(IrStrengthReduction.run(left) == left, "constant numerator");
	}
}
