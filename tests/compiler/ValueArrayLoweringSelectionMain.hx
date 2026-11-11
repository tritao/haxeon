import compiler.ir.Ir;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import compiler.ir.IrValueArrayProgramRewrite;
import compiler.compilation.AllocationMeter;

/** Adding element shapes must not multiply allocation for bodies with no array operations. */
class ValueArrayLoweringSelectionMain {
	/**
	 * Bytes one more element shape may cost per unrelated function (one with no array operation). A shape's pass still visits every function
	 * once, to find out it is not selected, and fills one slot of the result: today that is about 95 bytes. The bound sits just above, so a
	 * per-function, per-shape allocation of any size (a key string, a map, a copy of the function array) fails here. The true-zero version
	 * is a pass that never visits unrelated functions per shape; it is a recorded option (docs/WARM_REBUILD_REUSE.md), not a requirement.
	 */
	static inline final MAX_BYTES_PER_FUNCTION_PER_SHAPE = 128.0;

	static inline final FUNCTIONS = 128;

	static function main():Void {
		var one = overhead(1), eight = overhead(8);
		// The ratio alone passed while a per-shape cost sat behind a constant part (the operand arrays of the bodies): the slope is the measure.
		var slope = (eight - one) / 7 / FUNCTIONS;
		if (one <= 0 || eight > one * 3)
			throw 'Unrelated bodies were rebuilt per element shape: one=$one eight=$eight';
		if (slope > MAX_BYTES_PER_FUNCTION_PER_SHAPE)
			throw 'An element shape costs $slope bytes per unrelated function, above ${MAX_BYTES_PER_FUNCTION_PER_SHAPE}: one=$one eight=$eight';
		Sys.println('PASS: unrelated body allocation stays bounded across element shapes ($one / $eight bytes, ${Math.round(slope)} bytes per function per shape)');
	}

	static function overhead(shapes:Int):Float
		return measure(shapes, FUNCTIONS) - measure(shapes, 0);

	static function measure(shapes:Int, functions:Int):Float {
		var program = new IrProgram("main"), entry = new IrBuilder();
		entry.returnValue(entry.constInt(42));
		program.functions.push(new IrFunction("main", entry.arguments, I32, entry.blocks, None, []));
		for (i in 0...shapes) {
			var name = "Record" + i;
			program.objects.push({
				name: name,
				isValue: true,
				base: null,
				interfaces: [],
				methods: [],
				fields: [{name: "x", type: I32}]
			});
			program.staticFields.push({name: "values" + i, type: Array(Obj(name))});
		}
		for (i in 0...functions) {
			var b = new IrBuilder(), result = b.constInt(i);
			for (j in 0...20)
				result = b.add(result, b.constInt(j));
			b.returnValue(result);
			program.functions.push(new IrFunction("unrelated" + i, b.arguments, I32, b.blocks, None, []));
		}
		var before = AllocationMeter.sample();
		IrValueArrayProgramRewrite.rewriteAll(program, 64, HashLink);
		var bytes = AllocationMeter.sample().bytes - before.bytes;
		compiler.ir.IrVerifier.verify(program);
		return bytes;
	}
}
