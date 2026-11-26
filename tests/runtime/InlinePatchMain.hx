using compiler.compilation.BackendArtifact.BackendArtifacts;
import compiler.Compiler;
import compiler.ir.passes.inlining.IrInliner;
import runtime.PatchSet;
import runtime.Runtime;

/** A callee edit must reach the live module in every function that inlined it, and only those. */
class InlinePatchMain {
	static function main():Void {
		var compiler = new Compiler();
		var program = (body:String,
			extra:String) -> "class Counter { public static var value:Int = 40; public static function bump():Int { "
			+ body
			+ " return value; } } function other():Int { return 5; } "
			+ extra
			+ "function main():Int { return Counter.bump() + other(); }";
		compiler.update("Main.hx", program("value++;", ""));
		var first = compiler.compile("Main"),
			live = Runtime.load(first.artifact.hashLink().hashLinkBytes().flatten(),
				first.artifact.hashLink().runtimeIdentity),
			mainId = Runtime.requireFunctionId(live, "main");
		if (Runtime.callInt(live, mainId) != 46)
			throw "Inlined program did not run correctly before the edit";
		compiler.update("Main.hx", program("value++; value++;", ""));
		var changed = compiler.compile("Main");
		if (changed.requiresReload || changed.artifact.hashLink().patchBytes == null)
			throw "A callee body edit did not produce a compatible patch";
		// The compiler reports the functions it lowered again by name.
		var patched = changed.changedFunctions;
		if (patched.indexOf("Counter.bump") < 0)
			throw "The edited callee was not patched";
		if (patched.indexOf("main") < 0)
			throw "The caller that inlined the edited callee was not patched";
		var compiled = Runtime.patchJitCount(live);
		Runtime.patchSet(live,
			new PatchSet(first.revision, changed.revision, changed.artifact.hashLink().patchBytes,
			changed.changedFunctions));
		// The runtime compiles only the functions whose linked code changed: other is lowered again to the same code.
		if (Runtime.patchJitCount(live) - compiled != 2)
			throw 'The patch compiled ${Runtime.patchJitCount(live) - compiled} functions, not the callee and its inlining caller';
		// bump ran once before the edit (41); now twice per call: 41 -> 43, plus other().
		if (Runtime.callInt(live, mainId) != 48)
			throw "The inlined caller kept the old callee body after the patch";
		Runtime.dispose(live);
		Sys.println("PASS: a callee edit patches every function that inlined it");
	}
}
