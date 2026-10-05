import compiler.Frontend;
import compiler.ir.Ir;
import compiler.ir.IrFunction;
import compiler.ir.IrInliner;
import compiler.ir.IrInliner.InlineMemo;
import compiler.ir.IrInliner.IrInlineCache;
import compiler.ir.IrVerifier;

class InlinerMain {
	static function main():Void {
		// This unit suite exercises inlining explicitly, independently of the frontend option.
		IrInliner.enabled = true;
		var source = "@:value class P { public var a:Int; public function new(a:Int) this.a = a; public function twiceA():Int return a + a; } "
			+ "function twice(x:Int):Int return x + x; "
			+ "inline function pickFirst(flag:Bool, a:Int, b:Int):Int { if (flag) return a; return b; } "
			+ "function loops(n:Int):Int { var total = 0; for (i in 0...n) total += i; return total; } "
			+ "function fib(n:Int):Int return n < 2 ? n : fib(n - 1) + fib(n - 2); "
			+ "function withTry(n:Int):Int { try { return n; } catch (error:Dynamic) { return 0; } } "
			+ "function main():Int { var p = new P(4); return twice(3) + pickFirst(true, 1, 2) + p.twiceA() + loops(4) + fib(5) + withTry(1); }";
		var program = Frontend.compile(source);
		var before:Map<String, IrFunction> = [];
		for (fn in program.functions)
			before.set(fn.name, fn);
		var originals = program.functions.copy(), cache = new IrInlineCache();
		var changed = IrInliner.run(program, cache).length;
		IrVerifier.verify(program);
		var after:Map<String, IrFunction> = [];
		for (fn in program.functions)
			after.set(fn.name, fn);
		expect(changed > 0, "the inliner should rewrite at least one function");
		expect(after.get("twice") == before.get("twice"), "a function with no inlinable calls keeps its identity");
		var mainCalls = callsIn(after.get("main"));
		expect(mainCalls.indexOf("twice") < 0, "twice should be inlined into main");
		expect(mainCalls.indexOf("pickFirst") < 0, "an inline function with several returns should be inlined into main");
		expect(mainCalls.indexOf("P.twiceA") < 0, "a value class method should be inlined into main");
		expect(mainCalls.indexOf("fib") >= 0, "a recursive function must stay a call");
		expect(mainCalls.indexOf("withTry") >= 0, "a callee with exception handling must stay a call");
		expect(callsIn(after.get("fib")).indexOf("fib") >= 0, "recursion must not be unrolled away");
		expect(before.get("main") != after.get("main"), "the original main must be left untouched for the IR cache");
		expect(callsIn(before.get("main")).indexOf("twice") >= 0, "the cached IR of main must still contain the call");
		// Scalar replacement removes an allocation that never leaves its block, and only then.
		var scalarProgram = Frontend.compile("@:value class P { public var a:Int; public var b:Int; public function new(a:Int, b:Int) { this.a = a; this.b = b; } "
			+ "public function sum():Int return a + b; } function keep(p:P):Int { var t = 0; for (i in 0...3) t += p.a * i; return t; } "
			+ "function gone():Int { var p = new P(1, 2); return p.sum(); } "
			+ "function escapes():Int { var p = new P(1, 2); return keep(p); } function main():Int return gone() + escapes();");
		IrInliner.run(scalarProgram, new IrInlineCache());
		IrVerifier.verify(scalarProgram);
		expect(allocations(programFunction(scalarProgram, "gone")) == 0, "an object used only through fields in one block should be scalar replaced");
		expect(allocations(programFunction(scalarProgram, "escapes")) == 1, "an object passed to a call that is not inlined must stay allocated");
		// Uses spread over branches and loops turn fields into phis. That only pays when the allocation runs repeatedly, so an
		// object created once keeps its allocation and one created inside a loop loses it.
		var flowProgram = Frontend.compile("@:value class Acc { public var count:Int; public var total:Int; public function new() {} "
			+ "public function add(v:Int):Void { count = count + 1; total = total + v; } } "
			+ "function keep(a:Acc):Int { var t = 0; for (i in 0...3) t += a.total * i; return t; } "
			+ "function branches(flag:Bool):Int { var a = new Acc(); a.add(1); if (flag) a.add(2); return a.total; } "
			+ "function loops(n:Int):Int { var a = new Acc(); for (i in 0...n) a.add(i); return a.total + a.count; } "
			+
			"function perIteration(n:Int):Int { var t = 0; for (i in 0...n) { var a = new Acc(); a.add(i); if (i % 2 == 0) a.add(1); t += a.total; } return t; } "
			+
			"function perIterationNested(n:Int):Int { var t = 0; for (i in 0...n) { var a = new Acc(); for (j in 0...3) a.add(j); t += a.total + a.count; } return t; } "
			+ "function late(n:Int):Int { var a = new Acc(); for (i in 0...n) a.add(i); return keep(a); } "
			+ "function guarded(n:Int):Int { var a = new Acc(); try { a.add(n); } catch (e:Dynamic) { return -1; } return a.total; } "
			+ "function main():Int return branches(true) + loops(3) + perIteration(4) + perIterationNested(2) + late(3) + guarded(2);");
		IrInliner.run(flowProgram, new IrInlineCache());
		IrVerifier.verify(flowProgram);
		for (name in ["branches", "loops"])
			expect(allocations(programFunction(flowProgram, name)) == 1, '$name allocates once, and needs phis to replace it');
		// An argument is a copy, but keep only reads it and stores nothing, so the copy is dropped.
		expect(allocations(programFunction(flowProgram, "late")) == 1, "late passes its object to keep without copying it");
		for (name in ["perIteration", "perIterationNested"])
			expect(allocations(programFunction(flowProgram, name)) == 0, '$name allocates every iteration, so it should be replaced even with phis');
		expect(allocations(programFunction(flowProgram, "guarded")) <= 1, "an object in a function with exception handling is handled safely");
		// Where a value field is stored inline, `field = new V(...)` writes into the slot instead of allocating.
		var slotSource = "@:value class S { public var a:Int; public var b:Int; public function new(a:Int, b:Int) { this.a = a; this.b = b; } } "
			+ "class H { public var s:S; public function new() { s = new S(0, 0); } public function set(a:Int):Void { s = new S(a, 1); } } "
			+ "function main():Int { var h = new H(); h.set(3); return h.s.a; }";
		IrInliner.packedValueFields = true;
		var slotProgram = Frontend.compile(slotSource);
		IrInliner.run(slotProgram, new IrInlineCache());
		IrVerifier.verify(slotProgram);
		expect(allocations(programFunction(slotProgram, "H.set")) == 0, "storing a new value into an inline field should not allocate");
		IrInliner.packedValueFields = false;
		var boxedProgram = Frontend.compile(slotSource);
		IrInliner.run(boxedProgram, new IrInlineCache());
		expect(allocations(programFunction(boxedProgram, "H.set")) == 1, "a target without inline value fields keeps the allocation");
		// A copy stays whenever the callee could observe the difference.
		var readsOnlyBody = "function readsOnly(b:Box):Int { var t = 0; for (i in 0...3) t += b.v * i; return t; }";
		var elisionSource = (readsOnlyBody:String) -> ("@:value class Box { public var v:Int; public function new(v:Int) this.v = v; } "
			+ "class Sink { public static var kept:Box = new Box(0); } "
			+ readsOnlyBody
			+ " "
			+ "function writes(b:Box):Int { for (i in 0...3) b.v = b.v + i; return b.v; } "
			+ "function escapes(b:Box):Int { Sink.kept = b; return 1; } "
			+ "function storesElsewhere(b:Box, other:Box):Int { var t = 0; for (i in 0...3) { other.v = other.v + 1; t += b.v; } return t; } "
			+ "function noise():Int return 3; "
			+ "function pureCaller(x:Box):Int return readsOnly(x); "
			+ "function writeCaller(x:Box):Int return writes(x); "
			+ "function escapeCaller(x:Box):Int return escapes(x); "
			+ "function storeCaller(x:Box, y:Box):Int return storesElsewhere(x, y); "
			+ "function gapCaller(x:Box):Int { return readsOnlyWith(x, noise()); } "
			+ "function readsOnlyWith(b:Box, n:Int):Int { var t = 0; for (i in 0...n) t += b.v; return t; } "
			+
			"function main():Int { var a = new Box(2); var b = new Box(3); return pureCaller(a) + writeCaller(a) + escapeCaller(a) + storeCaller(a, b) + gapCaller(a); }");
		var elisionProgram = Frontend.compile(elisionSource(readsOnlyBody));
		var elisionOriginals = elisionProgram.functions.copy(),
			elisionCache = new IrInlineCache();
		IrInliner.run(elisionProgram, elisionCache);
		IrVerifier.verify(elisionProgram);
		expect(allocations(programFunction(elisionProgram, "pureCaller")) == 0, "a read-only, store-free callee gets the source itself");
		// Editing the callee so that it writes its parameter must give the caller its copy back.
		var writingBody = "function readsOnly(b:Box):Int { var t = 0; for (i in 0...3) { b.v = b.v + 1; t += b.v; } return t; }";
		var editedElision = Frontend.compile(elisionSource(writingBody));
		var elisionHybrid:Array<IrFunction> = [];
		for (fn in elisionOriginals)
			elisionHybrid.push(fn.name == "readsOnly" ? programFunction(editedElision, "readsOnly") : fn);
		elisionProgram.functions = elisionHybrid;
		var elisionChanged = IrInliner.run(elisionProgram, elisionCache);
		expect(elisionChanged.indexOf("pureCaller") >= 0, "a caller whose callee started writing its parameter is reported as changed");
		expect(allocations(programFunction(elisionProgram, "pureCaller")) == 1, "the caller gets its copy back once the callee writes the parameter");
		expect(allocations(programFunction(elisionProgram, "writeCaller")) == 1, "a callee that writes its parameter must get a copy");
		expect(allocations(programFunction(elisionProgram, "escapeCaller")) == 1, "a callee that stores its parameter must get a copy");
		// Both arguments are copies: one is written by the callee, and the other could alias what the callee stores into.
		expect(allocations(programFunction(elisionProgram, "storeCaller")) == 2, "a callee that stores elsewhere could alias the source, so it gets a copy");
		// A virtual call resolves when the receiver's class and all its subclasses share one implementation.
		var hierarchy = Frontend.compile("class Base { public var n:Int; public function new(n:Int) this.n = n; public function get():Int return n; "
			+ "public function twice():Int return n * 2; } class Derived extends Base { public function new(n:Int) super(n); "
			+ "override public function get():Int return n + 100; } class Leaf { public var v:Int; public function new(v:Int) this.v = v; "
			+ "public function value():Int return v; } class LeafChild extends Leaf { public function new(v:Int) super(v); } "
			+ "function viaBase(b:Base):Int return b.get() + b.twice(); function viaLeaf(l:Leaf):Int return l.value() + 1; "
			+ "function main():Int return viaBase(new Derived(1)) + viaLeaf(new LeafChild(2));");
		IrInliner.run(hierarchy, new IrInlineCache());
		IrVerifier.verify(hierarchy);
		var baseCalls = callsIn(programFunction(hierarchy, "viaBase"));
		expect(baseCalls.indexOf("get") >= 0, "an overridden method must stay a virtual call");
		expect(baseCalls.indexOf("twice") < 0, "an inherited method nobody overrides resolves and inlines");
		expect(callsIn(programFunction(hierarchy, "viaLeaf")).indexOf("value") < 0, "a method with no override in the program resolves and inlines");
		// A memo entry records the objects its inlining looked at, so a class that none of them touched leaves it alone: it is kept
		// as it is, not worked out again to the same bytes.
		var grown = Frontend.compile("class Base { public var n:Int; public function new(n:Int) this.n = n; public function get():Int return n; "
			+ "public function twice():Int return n * 2; } class Derived extends Base { public function new(n:Int) super(n); "
			+ "override public function get():Int return n + 100; } class Leaf { public var v:Int; public function new(v:Int) this.v = v; "
			+ "public function value():Int return v; } class LeafChild extends Leaf { public function new(v:Int) super(v); } "
			+ "function viaBase(b:Base):Int return b.get() + b.twice(); function viaLeaf(l:Leaf):Int return l.value() + 1; "
			+ "function main():Int return viaBase(new Derived(1)) + viaLeaf(new LeafChild(2));");
		var grownPristine = grown.functions.copy(),
			grownObjects = grown.objects.copy(),
			grownCache = new IrInlineCache();
		IrInliner.run(grown, grownCache);
		var memosBefore:Map<String, InlineMemo> = [for (name => memo in grownCache.memo) name => memo];
		grown.functions = grownPristine.copy();
		grown.objects = grownObjects.concat([
			{
				name: "Unrelated",
				isValue: false,
				base: null,
				interfaces: [],
				fields: [],
				methods: []
			}
		]);
		expect(IrInliner.run(grown, grownCache).length == 0, "a new class changes no function");
		for (name => memo in memosBefore)
			expect(grownCache.memo.get(name) == memo, 'a new class that $name never looked at must not redo it');
		// A new subclass that overrides a method resolved through its base changes the functions that looked at that base, and only those.
		grown.functions = grownPristine.copy();
		grown.objects = grownObjects.concat([
			{
				name: "Override",
				isValue: false,
				base: "Base",
				interfaces: [],
				fields: [],
				methods: [{name: "twice", functionName: "Override.twice"}]
			}
		]);
		var overridden = IrInliner.run(grown, grownCache);
		expect(overridden.indexOf("viaBase") >= 0, "a function that resolved a method through the base is redone when a subclass overrides it");
		expect(callsIn(programFunction(grown, "viaBase")).indexOf("twice") >= 0, "an overridden method is no longer inlined");
		expect(grownCache.memo.get("viaLeaf") == memosBefore.get("viaLeaf"), "a function that never looked at the base is not redone");
		expect(overridden.indexOf("viaLeaf") < 0, "a function that never looked at the base is not reported");
		// Unchanged input: every function keeps its inlined identity and nothing is reported as changed.
		var inlinedMain = after.get("main");
		program.functions = originals.copy();
		expect(IrInliner.run(program, cache).length == 0, "an unchanged program must report no changed functions");
		expect(programFunction(program, "main") == inlinedMain, "an unchanged caller keeps its inlined identity");
		// Editing a callee changes exactly the functions that inlined it.
		var edited = Frontend.compile(StringTools.replace(source, "function twice(x:Int):Int return x + x;", "function twice(x:Int):Int return x * 2;"));
		var hybrid:Array<IrFunction> = [];
		for (fn in originals)
			hybrid.push(fn.name == "twice" ? programFunction(edited, "twice") : fn);
		program.functions = hybrid;
		var names = IrInliner.run(program, cache);
		expect(names.indexOf("twice") >= 0, "the edited callee is reported as changed");
		expect(names.indexOf("main") >= 0, "a caller that inlined the edited callee is reported as changed");
		expect(names.indexOf("fib") < 0 && names.indexOf("loops") < 0, "functions that did not inline the callee are not reported");
		// A rolled-back candidate must not disturb the published cache.
		var branch = cache.copy();
		program.functions = originals.copy();
		IrInliner.run(program, branch);
		program.functions = hybrid;
		expect(IrInliner.run(program, cache).length == 0, "the published cache is unaffected by a discarded copy");
		Sys.println("PASS: inliner replaces small calls, keeps recursion and handlers, verifies, and leaves cached IR alone");
	}

	static function programFunction(program:IrProgram, name:String):IrFunction {
		for (fn in program.functions)
			if (fn.name == name)
				return fn;
		throw 'Missing function $name';
	}

	static function allocations(fn:IrFunction):Int {
		var count = 0;
		for (block in fn.blocks)
			for (located in block.instructions)
				switch located.value {
					case NewObject(_, _):
						count++;
					default:
				}
		return count;
	}

	static function callsIn(fn:IrFunction):Array<String> {
		var names:Array<String> = [];
		for (block in fn.blocks)
			for (located in block.instructions)
				switch located.value {
					case Call(_, name, _):
						names.push(name);
					case MethodCall(_, _, name, _):
						names.push(name);
					default:
				}
		return names;
	}

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}
}
