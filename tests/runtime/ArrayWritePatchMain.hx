import compiler.hl.HlWriter;
import compiler.Compiler;
import compiler.runtime.CompilerIntrinsics;
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
		// The runtime fast paths also introduce Ref/Unref/Setref/RefOffset instructions and Ref types in patches.
		var fastCompiler = new Compiler();
		CompilerIntrinsics.register(fastCompiler);
		fastCompiler.addSourceRoot("stdlib");
		var fastProgram = (value:Int) ->
			'import haxe.io.Bytes; function main():Int {var a=[0,0,0];a.resize(0);var b=Bytes.alloc(1);a.push($value);b.set(0,a[0]);return b.get(0);}';
		fastCompiler.update("Main.hx", fastProgram(9));
		var initialFast = fastCompiler.compile("Main");
		var fastLive = Runtime.load(HlWriter.encode(initialFast.module), initialFast.runtimeIdentity);
		var fastMain = initialFast.functionIds.get("main");
		if (Runtime.callInt(fastLive, fastMain) != 9)
			throw "Initial inline runtime operations failed";
		fastCompiler.update("Main.hx", fastProgram(42));
		var editedFast = fastCompiler.compile("Main");
		if (editedFast.requiresReload || editedFast.patchBytes == null)
			throw "Inline runtime operations did not produce a patch";
		Runtime.patchSet(fastLive, new PatchSet(initialFast.revision, editedFast.revision, editedFast.patchBytes, editedFast.changedFunctions));
		if (Runtime.callInt(fastLive, fastMain) != 42)
			throw "Patched inline runtime operations failed";
		Runtime.dispose(fastLive);
		Sys.println("PASS: array writes and inline array/byte operations are patchable");
	}
}
