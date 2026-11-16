using compiler.compilation.BackendArtifact.BackendArtifacts;
import compiler.Compiler;
import compiler.hl.HlWriter;
import compiler.hl.patch.HlPatchReader;
import compiler.ir.IrInliner;
import runtime.PatchSet;
import runtime.Runtime;

/** A callee edit must reach the live module in every function that inlined it, and only those. */
class InlinePatchMain {
	static function main():Void {
		IrInliner.enabled = true;
		var compiler = new Compiler();
		var program = (body:String,
			extra:String) -> "class Counter { public static var value:Int = 40; public static function bump():Int { "
			+ body
			+ " return value; } } function other():Int { return 5; } "
			+ extra
			+ "function main():Int { return Counter.bump() + other(); }";
		compiler.update("Main.hx", program("value++;", ""));
		var first = compiler.compile("Main"),
			live = Runtime.load(HlWriter.encode(first.artifact.hashLink().module).flatten(),
				first.artifact.hashLink().runtimeIdentity),
			mainId = first.artifact.hashLink().functionIds.get("main"),
			bumpId = first.artifact.hashLink().functionIds.get("Counter.bump"),
			otherId = first.artifact.hashLink().functionIds.get("other");
		if (Runtime.callInt(live, mainId) != 46)
			throw "Inlined program did not run correctly before the edit";
		compiler.update("Main.hx", program("value++; value++;", ""));
		var changed = compiler.compile("Main");
		if (changed.requiresReload || changed.artifact.hashLink().patchBytes == null)
			throw "A callee body edit did not produce a compatible patch";
		var patched =
			[for (fn in HlPatchReader.decode(changed.artifact.hashLink().patchBytes).functions) fn.functionIndex];
		if (patched.indexOf(bumpId) < 0)
			throw "The edited callee was not patched";
		if (patched.indexOf(mainId) < 0)
			throw "The caller that inlined the edited callee was not patched";
		if (patched.indexOf(otherId) >= 0)
			throw "A function that did not inline the callee was patched";
		Runtime.patchSet(live,
			new PatchSet(first.revision, changed.revision, changed.artifact.hashLink().patchBytes,
			changed.changedFunctions));
		// bump ran once before the edit (41); now twice per call: 41 -> 43, plus other().
		if (Runtime.callInt(live, mainId) != 48)
			throw "The inlined caller kept the old callee body after the patch";
		Runtime.dispose(live);
		Sys.println("PASS: a callee edit patches every function that inlined it");
	}
}
