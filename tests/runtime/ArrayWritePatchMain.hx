import compiler.hl.HlWriter;
import compiler.Compiler;
import runtime.PatchSet;
import runtime.Runtime;

/** An array write lowers to the array's data pointer and a memory store (ORefData, OSetMem), which a patch must accept as
	the module load does. */
class ArrayWritePatchMain {
	static function main():Void {
		var compiler = new Compiler();
		var program = (value:Int) -> "class Slots { public static function run():Int { var slots = [0, 0, 0]; slots[1] = "
			+ value
			+ "; return slots[1] + slots.length; } } function main():Int { return Slots.run(); }";
		compiler.update("Main.hx", program(9));
		var first = compiler.compile("Main"),
			live = Runtime.load(HlWriter.encode(first.module), first.runtimeIdentity),
			mainId = first.functionIds.get("main");
		if (Runtime.callInt(live, mainId) != 12)
			throw "The array-write program did not run correctly before the edit";
		compiler.update("Main.hx", program(20));
		var changed = compiler.compile("Main");
		if (changed.requiresReload || changed.patchBytes == null)
			throw "A body edit did not produce a compatible patch";
		Runtime.patchSet(live, new PatchSet(first.revision, changed.revision, changed.patchBytes, changed.changedFunctions));
		if (Runtime.callInt(live, mainId) != 23)
			throw "The patched function kept its old body";
		Runtime.dispose(live);
		Sys.println("PASS: a function that writes an array element is patchable");
	}
}
