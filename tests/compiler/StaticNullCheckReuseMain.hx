import compiler.ir.Ir;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import compiler.ir.IrStaticNullChecks;
import compiler.ir.IrStaticNullChecks.IrStaticCheckCache;
import compiler.ir.SourceProvenance;
import compiler.ir.SourceProvenance.Located;
import compiler.ir.codec.IrFunctionStateCodec;

/** The static null-check pass must give an unchanged function the same object every compile, and the same result as a pass with no cache. */
class StaticNullCheckReuseMain {
	static function expect(ok:Bool, message:String):Void {
		if (!ok)
			throw message;
	}

	// A function that reads a field of a static, so it gets a check and a shared helper.
	static function reader(name:String, global:String, offset:Int):IrFunction {
		var b = new IrBuilder();
		var g = new IrValue(100, "g", Obj("Box"));
		b.blocks[0].instructions.push(new Located(GlobalGet(g, global), SourceProvenance.generated("test")));
		var v = b.fieldGet(g, "v", I32);
		b.returnValue(b.add(v, b.constInt(offset)));
		return new IrFunction(name, b.arguments, I32, b.blocks);
	}

	static function caller(name:String, callees:Array<String>):IrFunction {
		var b = new IrBuilder();
		for (callee in callees)
			b.call(callee, [], I32);
		b.returnValue(b.constVoid());
		return new IrFunction(name, b.arguments, Void, b.blocks);
	}

	static function program(offset:Int):Array<IrFunction>
		return [caller("__init", ["readA", "readB"]), reader("readA", "S.a", offset), reader("readB", "S.b", 2), reader("unreached", "S.a", 3)];

	static function bytes(fn:IrFunction):String
		return IrFunctionStateCodec.encode(fn).toHex();

	static function sameAsUncached(cached:Array<IrFunction>, input:Array<IrFunction>):Void {
		var plain = IrStaticNullChecks.run(input);
		expect(plain.length == cached.length, "a cached run returns the same functions as an uncached run");
		for (index in 0...plain.length) {
			expect(plain[index].name == cached[index].name, "a cached run keeps the order");
			expect(bytes(plain[index]) == bytes(cached[index]), 'a cached run builds the same ${plain[index].name} as an uncached run');
		}
	}

	static function byName(functions:Array<IrFunction>):Map<String, IrFunction>
		return [for (fn in functions) fn.name => fn];

	static function main():Void {
		var cache = new IrStaticCheckCache();
		var first = IrStaticNullChecks.run(program(1), null, cache);
		expect(byName(first).exists("__static$nonnull$S.a"), "a read of a static gets its null-check helper");
		sameAsUncached(first, program(1));
		// The next compile rebuilds the unchanged functions from the same objects; nothing is redone.
		var sources = program(1);
		var one = IrStaticNullChecks.run(sources, null, cache);
		var again = IrStaticNullChecks.run(sources, null, cache);
		for (index in 0...one.length)
			expect(one[index] == again[index], 'an unchanged ${one[index].name} keeps its identity');
		sameAsUncached(again, sources);
		// Editing one function changes that function and nothing else.
		var edited = sources.copy();
		edited[1] = reader("readA", "S.a", 9);
		var changed = IrStaticNullChecks.run(edited, null, cache);
		var before = byName(again), after = byName(changed);
		expect(after.get("readA") != before.get("readA"), "an edited function is rebuilt");
		for (name in ["__init", "readB", "unreached", "__static$nonnull$S.a", "__static$nonnull$S.b"])
			expect(after.get(name) == before.get(name), 'an unedited $name keeps its identity');
		sameAsUncached(changed, edited);
		// A function that stops being reachable from initialization comes back unchanged and is not served from the cache.
		var unreachable = edited.copy();
		unreachable[0] = caller("__init", ["readB"]);
		var pruned = byName(IrStaticNullChecks.run(unreachable, null, cache));
		expect(pruned.get("readA") == unreachable[1], "an unreachable function is passed through");
		sameAsUncached(IrStaticNullChecks.run(unreachable, null, cache), unreachable);
		Sys.println("static null-check reuse OK");
	}
}
