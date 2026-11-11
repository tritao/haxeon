import compiler.ir.Ir;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import compiler.ir.IrScalarClosures;
import compiler.compilation.AllocationMeter;

class ScalarClosureSelectionMain {
	static function main():Void {
		for (count in [0, 250]) {
			var p = new IrProgram("main");
			p.objects.push({
				name: "Value",
				isValue: true,
				base: null,
				interfaces: [],
				methods: [],
				fields: [{name: "x", type: I32}]
			});
			var b = new IrBuilder(), arg = b.argument("v", Obj("Value"));
			b.returnValue(b.constInt(1));
			p.functions.push(new IrFunction("callee", b.arguments, I32, b.blocks, Ordinary));
			b = new IrBuilder();
			b.argument("v", I32);
			b.returnValue(b.constInt(1));
			p.functions.push(new IrFunction("$scalar-arguments:callee", b.arguments, I32, b.blocks, Ordinary));
			b = new IrBuilder();
			b.staticClosure("callee", Function([Obj("Value")], I32));
			b.returnValue(b.constInt(0));
			p.functions.push(new IrFunction("main", b.arguments, I32, b.blocks, Ordinary));
			for (i in 0...count) {
				b = new IrBuilder();
				var v = b.argument("v", I32);
				for (j in 0...64) {
					var next = b.createBlock();
					b.jump(next);
					b.select(next);
					v = b.add(v, b.constInt(j));
				}
				b.returnValue(v);
				p.functions.push(new IrFunction("f" + i, b.arguments, I32, b.blocks, Ordinary));
			}
			var original = p.functions.copy(),
				before = AllocationMeter.sample();
			IrScalarClosures.rewrite(p);
			var bytes = AllocationMeter.sample().bytes - before.bytes;
			var retained = 0;
			for (i in 3...original.length)
				if (p.functions[i] == original[i])
					retained++;
			if (bytes > 12 * 1024 * 1024)
				throw 'Unrelated closure bodies allocated $bytes bytes; expected less than 12 MiB';
			if (retained != count)
				throw "Unrelated closure bodies lost their identity";
			var redirected = false;
			for (block in p.functions[2].blocks)
				for (located in block.instructions)
					switch located.value {
						case StaticClosure(_, name) if (name == "$scalar-arguments:callee"):
							redirected = true;
						default:
					}
			if (!redirected)
				throw "Scalar closure was not redirected";
			for (i in 3...original.length)
				if (compiler.ir.codec.IrFunctionStateCodec.encode(original[i]).compare(compiler.ir.codec.IrFunctionStateCodec.encode(p.functions[i])) != 0)
					throw "Unrelated closure body state changed";
			compiler.ir.IrVerifier.verify(p);
		}
		Sys.println("PASS: scalar closure lowering retains unrelated CFGs and redirects affected closures");
	}
}
