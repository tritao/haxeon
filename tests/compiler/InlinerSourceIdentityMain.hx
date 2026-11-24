import compiler.core.AllocationMeter;
import compiler.ir.codec.IrFunctionStateCodec;
import compiler.ir.model.Ir;
import compiler.ir.model.IrBuilder;
import compiler.ir.model.IrFunction;
import compiler.ir.passes.inlining.IrInliner;
import compiler.ir.passes.inlining.IrInliner.IrInlineCache;

class InlinerSourceIdentityMain {
	static function program(amount:Int):IrProgram {
		var p = new IrProgram("caller0"),
			b = new IrBuilder(),
			value = b.argument("value", I32);
		for (i in 0...8)
			value = b.add(value, b.constInt(amount));
		b.returnValue(value);
		p.functions.push(new IrFunction("leaf", b.arguments, I32, b.blocks, Ordinary));
		for (i in 0...200) {
			b = new IrBuilder();
			value = b.argument("value", I32);
			for (j in 0...32)
				value = b.call("leaf", [value], I32);
			b.returnValue(value);
			p.functions.push(new IrFunction("caller" + i, b.arguments, I32, b.blocks, Ordinary));
		}
		return p;
	}

	static function main():Void {
		var session = new InlinerSession(), first = program(1);
		session.run(first);
		var entry = session.entry("caller0");
		if (entry == null)
			throw "The inliner kept no entry for caller0";
		var again = program(1),
			before = AllocationMeter.sample();
		var changed = session.run(again);
		var bytes = AllocationMeter.sample().bytes - before.bytes;
		if (session.entry("caller0") != entry || changed.length != 0)
			throw "Regenerated identical input must reuse the inlining memo";
		if (bytes > 8 * 1024 * 1024)
			throw 'Regenerated input allocated $bytes bytes, expected less than 8 MiB';
		var edited = program(2);
		changed = session.copy().run(edited);
		if (changed.length != 201)
			throw 'A callee edit changed ${changed.length} functions, not the callee and its 200 callers';
		var fresh = program(2);
		IrInliner.run(fresh, new IrInlineCache(), compiler.ir.pipeline.TargetProfile.wasm);
		same(edited, fresh, "Callee edit differs from a cold inlining run");
		var unchanged = program(1), cold = program(1);
		session.run(unchanged);
		IrInliner.run(cold, new IrInlineCache(), compiler.ir.pipeline.TargetProfile.wasm);
		same(unchanged, cold,
			"The program before the edit, built again after a speculative copy, differs from a cold run");
		Sys.println("PASS: regenerated IR reuses inlining while callee edits invalidate its callers");
	}

	static function same(left:IrProgram, right:IrProgram, message:String):Void {
		for (i in 0...right.functions.length)
			if (IrFunctionStateCodec.encode(left.functions[i])
				.compare(IrFunctionStateCodec.encode(right.functions[i])) != 0)
				throw message;
	}
}
