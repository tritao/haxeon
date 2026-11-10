import compiler.ir.Ir;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import compiler.ir.IrInliner;
import compiler.ir.IrInliner.IrInlineCache;
import compiler.ir.codec.IrFunctionStateCodec;
import compiler.compilation.AllocationMeter;

class InlinerSourceIdentityMain {
	static function program(amount:Int):IrProgram {
		var p = new IrProgram("caller0"),
			b = new IrBuilder(),
			value = b.argument("value", I32);
		for (i in 0...8)
			value = b.add(value, b.constInt(amount));
		b.returnValue(value);
		p.functions.push(new IrFunction("leaf", b.arguments, I32, b.blocks));
		for (i in 0...200) {
			b = new IrBuilder();
			value = b.argument("value", I32);
			for (j in 0...32)
				value = b.call("leaf", [value], I32);
			b.returnValue(value);
			p.functions.push(new IrFunction("caller" + i, b.arguments, I32, b.blocks));
		}
		return p;
	}

	static function main():Void {
		var cache = new IrInlineCache(), first = program(1);
		IrInliner.run(first, cache, compiler.ir.TargetProfile.wasm, true);
		var memo = cache.memo.get("caller0");
		var again = program(1),
			before = AllocationMeter.sample(),
			cpu = Sys.cpuTime(),
			wall = Sys.time();
		var changed = IrInliner.run(again, cache, compiler.ir.TargetProfile.wasm, true);
		var bytes = AllocationMeter.sample().bytes - before.bytes,
			used = Sys.cpuTime() - cpu,
			elapsed = Sys.time() - wall;
		if (cache.memo.get("caller0") != memo || changed.length != 0)
			throw "Regenerated identical input must reuse the inlining memo";
		if (Sys.getEnv("HAXEON_CHECK_REUSE") != "1" && bytes > 8 * 1024 * 1024)
			throw 'Regenerated input allocated $bytes bytes, expected less than 8 MiB';
		var fork = cache.copy();
		var edited = program(2);
		IrInliner.run(edited, fork, compiler.ir.TargetProfile.wasm, true);
		var fresh = program(2);
		IrInliner.run(fresh, new IrInlineCache(), compiler.ir.TargetProfile.wasm, true);
		for (i in 0...fresh.functions.length)
			if (IrFunctionStateCodec.encode(edited.functions[i]).compare(IrFunctionStateCodec.encode(fresh.functions[i])) != 0)
				throw "Callee edit differs from a cold inlining run";
		var unchanged = program(1);
		IrInliner.run(unchanged, cache, compiler.ir.TargetProfile.wasm, true);
		if (cache.memo.get("caller0") != memo)
			throw "A speculative cache copy changed its parent's inputs";
		var placements = new IrInlineCache();
		var original = located("x", 0),
			equal = located("x", 0),
			rehashed = located("x // comment", 0),
			moved = located(" x", 1);
		if (placements.stableSources([original])[0] != original || placements.stableSources([equal])[0] != original)
			throw "Equal input should keep its immutable identity";
		if (placements.stableSources([rehashed])[0] != rehashed || placements.stableSources([moved])[0] != moved)
			throw "Changed source hashes or offsets must keep their fresh provenance";
		placements.stableSources([]);
		if (placements.stableSources([equal])[0] != equal)
			throw "Removed inputs should be pruned";
		Sys.println("PASS: regenerated IR reuses inlining while callee edits and provenance invalidate safely");
	}

	static function located(text:String, start:Int):IrFunction {
		var b = new IrBuilder();
		b.returnValue(b.constInt(42));
		var block = b.blocks[0], term = block.terminator;
		block.terminator = new compiler.ir.SourceProvenance.Located(term.value,
			compiler.ir.SourceProvenance.user(new compiler.Source.SourceFile("same.hx", text).span(start, start + 1)));
		return new IrFunction("located", b.arguments, I32, b.blocks);
	}
}
