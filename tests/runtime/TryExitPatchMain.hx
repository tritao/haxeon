import compiler.hl.HlWriter;
import compiler.Compiler;
import runtime.PatchSet;
import runtime.Runtime;

/** A function that leaves a try body early closes its trap on each exit path, and must still be patchable. */
class TryExitPatchMain {
	static function main():Void {
		var compiler = new Compiler();
		var program = (early:Int, late:Int) -> "class Gate { public static var open:Bool = true; public static function pick():Int { try { if (open) return "
			+ early
			+ "; open = true; } catch (error:Dynamic) { return 0; } return "
			+ late
			+ "; } } function main():Int { var first = Gate.pick(); Gate.open = false; return first * 100 + Gate.pick(); }";
		compiler.update("Main.hx", program(1, 2));
		var first = compiler.compile("Main"),
			live = Runtime.load(HlWriter.encode(first.module), first.runtimeIdentity),
			mainId = first.functionIds.get("main");
		if (Runtime.callInt(live, mainId) != 102)
			throw "The early-exit program did not run correctly before the edit";
		compiler.update("Main.hx", program(3, 4));
		var changed = compiler.compile("Main");
		if (changed.requiresReload || changed.patchBytes == null)
			throw "A body edit did not produce a compatible patch";
		Runtime.patchSet(live, new PatchSet(first.revision, changed.revision, changed.patchBytes, changed.changedFunctions));
		// The first run left Gate.open true again, so the patched body takes the early exit and then the late one.
		if (Runtime.callInt(live, mainId) != 304)
			throw "The patched function kept its old body";
		Runtime.dispose(live);
		Sys.println("PASS: a function that leaves a try body early is patchable");
	}
}
