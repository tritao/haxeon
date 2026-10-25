import compiler.hl.HlWriter;
import compiler.ir.IrInliner;
import compiler.Compiler;
import runtime.PatchSet;
import runtime.Runtime;

/**
 * A patchable module's own bytecode calls its functions directly, as a normal module does, and the first patch of a function
 * redirects those calls by rewriting the function's original entry. Callers that go through that entry, directly, through a
 * stored closure or through an object's methods, all run the newest code after any number of patches.
 */
class DirectCallPatchMain {
	static function main():Void {
		// Small callees would otherwise be inlined, leaving no call to look at.
		IrInliner.enabled = false;
		var program = (v:Int, extra:Bool) -> "class Calc {\n"
			+ "  public static function leaf(x:Int):Int { return x + "
			+ v
			+ "; }\n"
			+ "  public static function tiny():Int { return "
			+ v
			+ "; }\n"
			+ "  public static function fact(n:Int):Int { if (n <= 1) return "
			+ v
			+ "; return n * fact(n - 1); }\n"
			+ "  public static function fail(x:Int):Int { if (x > 0) throw \"boom"
			+ v
			+ "\"; return x; }\n"
			+ "  public static function viaClosure():Int { var f = leaf; return f(10); }\n"
			+ (extra ? "  public static function added(x:Int):Int { return x * " + v + "; }\n" : "")
			+ "}\n"
			+ "class Box {\n"
			+ "  public function new() {}\n"
			+ "  public function get(x:Int):Int { return x + "
			+ v
			+ "; }\n"
			+ "}\n"
			+ "@:keep function callLeaf():Int { return Calc.leaf(5)"
			+ (extra ? " + Calc.added(2)" : "")
			+ "; }\n"
			+ "@:keep function callTiny():Int { return Calc.tiny(); }\n"
			+ "@:keep function callFact():Int { return Calc.fact(4); }\n"
			+ "@:keep function callClosure():Int { return Calc.viaClosure(); }\n"
			+ "@:keep function callBox():Int { return new Box().get(3); }\n"
			+ "@:keep function callCatch():Int { try { return Calc.fail(1); } catch (e:String) { return e.length * 100 + "
			+ v
			+ "; } }\n"
			+ "function main():Int { return callLeaf(); }\n";
		// What each entry point returns for a value of v.
		var expected = (v:Int, extra:Bool) -> [
			"Main.callLeaf" => 5 + v + (extra ? 2 * v : 0),
			"Main.callTiny" => v,
			"Main.callFact" => 24 * v,
			"Main.callClosure" => 10 + v,
			"Main.callBox" => 3 + v,
			"Main.callCatch" => ("boom" + v).length * 100 + v
		];
		var compiler = new Compiler();
		compiler.update("Main.hx", program(1, false));
		var build = compiler.compile("Main"),
			live = Runtime.load(HlWriter.encode(build.module), build.runtimeIdentity);
		var check = (label:String, v:Int, extra:Bool) -> {
			for (name => want in expected(v, extra)) {
				var got = Runtime.callInt(live, build.functionIds.get(name));
				if (got != want)
					throw 'After $label $name returned $got instead of $want';
			}
		};
		check("loading", 1, false);

		// The callers reach their callees with a call to the callee's own entry, not through the stub table.
		var direct = [
			"Main.callLeaf" => "Calc.leaf",
			"Main.callTiny" => "Calc.tiny",
			"Main.callFact" => "Calc.fact",
			"Main.callClosure" => "Calc.viaClosure",
			"Main.callCatch" => "Calc.fail"
		];
		for (caller => callee in direct)
			if (Runtime.callsDirectly(live, build.functionIds.get(caller), build.functionIds.get(callee)) != 1)
				throw '$caller does not call $callee directly';
		if (Runtime.callsDirectly(live, build.functionIds.get("Calc.fact"), build.functionIds.get("Calc.fact")) != 1)
			throw "A recursive function does not call itself directly";
		for (name in ["Calc.leaf", "Calc.tiny", "Calc.fact", "Calc.fail"])
			if (Runtime.entryState(live, build.functionIds.get(name)) != 0)
				throw 'The entry of $name was rewritten before any patch';

		var edits = [
			{label: "the first patch", v: 2, extra: false},
			{label: "a second patch, which adds a function", v: 3, extra: true},
			{label: "a third patch, which edits the added function", v: 4, extra: true},
			{label: "a patch back to the first values", v: 1, extra: true}
		];
		for (edit in edits) {
			compiler.update("Main.hx", program(edit.v, edit.extra));
			var changed = compiler.compile("Main");
			if (changed.requiresReload || changed.patchBytes == null)
				throw 'The edit for ${edit.label} required a reload: ${[for (reason in changed.reloadReasons) Std.string(reason)].join(", ")}';
			Runtime.patchSet(live, new PatchSet(build.revision, changed.revision, changed.patchBytes, changed.changedFunctions));
			build = changed;
			check(edit.label, edit.v, edit.extra);
			// Every patched function's original entry now jumps to its stub with one atomic store.
			for (name in ["Calc.leaf", "Calc.tiny", "Calc.fact", "Calc.fail"])
				if (Runtime.entryState(live, build.functionIds.get(name)) != 2)
					throw 'After ${edit.label} the entry of $name is in state ${Runtime.entryState(live, build.functionIds.get(name))}, not the atomic jump';
		}
		// A full module built from the last source runs the same, so the patched run was not special.
		var fresh = Runtime.load(HlWriter.encode(build.module), build.runtimeIdentity);
		var reloaded = Runtime.callInt(fresh, build.functionIds.get("Main.callLeaf"));
		Runtime.dispose(fresh);
		if (reloaded != expected(1, true).get("Main.callLeaf"))
			throw 'The full module returned $reloaded';
		Runtime.dispose(live);
		Sys.println("PASS: direct calls in a patchable module follow patches of their callees");
	}
}
