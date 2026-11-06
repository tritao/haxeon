import compiler.ir.Ir;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import compiler.ir.IrScalarReplacement;
import compiler.ir.IrValuePhiScalarization;
import compiler.ir.IrNullableScalarFlow;
import compiler.ir.IrObjectTable;
import compiler.compilation.AllocationMeter;

/** A value declaration must not make unrelated scalar CFGs pay for value analyses. */
class ScalarPreflightSelectionMain {
	static function main():Void {
		for (count in [0, 250]) {
			var program = new IrProgram("f0");
			program.objects.push({
				name: "Value",
				isValue: true,
				base: null,
				interfaces: [],
				methods: [],
				fields: [{name: "x", type: I32}]
			});
			for (i in 0...count + 1) {
				var builder = new IrBuilder(),
					value = builder.argument("v", I32);
				for (j in 0...64) {
					var next = builder.createBlock();
					builder.jump(next);
					builder.select(next);
					value = builder.add(value, builder.constInt(j));
				}
				builder.returnValue(value);
				program.functions.push(new IrFunction("f" + i, builder.arguments, I32, builder.blocks));
			}
			var original = program.functions.copy();
			var expected = compiler.ir.codec.CanonicalIrCodec.encode(program);
			var before = AllocationMeter.sample();
			IrValuePhiScalarization.rewrite(program);
			var table = IrObjectTable.of([for (object in program.objects) object.name => object]);
			program.functions = [
				for (fn in program.functions)
					IrScalarReplacement.rewrite(fn, table, false, true)
			];
			IrNullableScalarFlow.rewrite(program);
			var bytes = AllocationMeter.sample().bytes - before.bytes;
			if (bytes > 5 * 1024 * 1024)
				throw 'Scalar preflights allocated $bytes bytes; expected less than 5 MiB';
			if (compiler.ir.codec.CanonicalIrCodec.encode(program).compare(expected) != 0)
				throw "Unrelated scalar IR changed";
			for (i in 0...original.length)
				if (program.functions[i] != original[i])
					throw "Unrelated function identity changed";
			compiler.ir.IrVerifier.verify(program);
		}
		Sys.println("PASS: scalar analyses skip unrelated CFGs without changing their IR or identity");
	}
}
