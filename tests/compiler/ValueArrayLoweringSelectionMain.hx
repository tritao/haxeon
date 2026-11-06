import compiler.ir.Ir;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import compiler.ir.IrValueArrayProgramRewrite;
import compiler.compilation.AllocationMeter;

/** Adding element shapes must not multiply allocation for bodies with no array operations. */
class ValueArrayLoweringSelectionMain {
	static function main():Void {
		var one = overhead(1), eight = overhead(8);
		if (one <= 0 || eight > one * 3)
			throw 'Unrelated bodies were rebuilt per element shape: one=$one eight=$eight';
		Sys.println('PASS: unrelated body allocation stays bounded across element shapes ($one / $eight bytes)');
	}

	static function overhead(shapes:Int):Float
		return measure(shapes, 128) - measure(shapes, 0);

	static function measure(shapes:Int, functions:Int):Float {
		var program = new IrProgram("main"), entry = new IrBuilder();
		entry.returnValue(entry.constInt(42));
		program.functions.push(new IrFunction("main", entry.arguments, I32, entry.blocks));
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
			program.functions.push(new IrFunction("unrelated" + i, b.arguments, I32, b.blocks));
		}
		var before = AllocationMeter.sample();
		IrValueArrayProgramRewrite.rewriteAll(program, 64, HashLink);
		var bytes = AllocationMeter.sample().bytes - before.bytes;
		compiler.ir.IrVerifier.verify(program);
		return bytes;
	}
}
