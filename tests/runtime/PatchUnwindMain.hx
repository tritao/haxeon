import compiler.hl.HlWriter;
import compiler.Compiler;
import compiler.runtime.CompilerIntrinsics;
import runtime.PatchSet;
import runtime.Runtime;

/**
 * Windows walks exception stacks with the unwind tables the JIT registers, so patched code needs its own table and must
 * leave the module's table alone: a patched function that throws still reports itself and the unpatched frames below it.
 */
class PatchUnwindMain {
	static function main():Void {
		var compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addSourceRoot("stdlib");
		var program = (message:String) -> "import haxe.CallStack;\n"
			+ "function fail():Void { throw '"
			+ message
			+ "'; }\n"
			+ "function probe():Int { try { fail(); } catch (error:Dynamic) { var stack = CallStack.toString(CallStack.exceptionStack());"
			+ " return (stack.indexOf('fail') >= 0 ? 1 : 0) + (stack.indexOf('probe') >= 0 ? 2 : 0) + (stack.indexOf('main') >= 0 ? 4 : 0); } }\n"
			+ "function main():Int { return probe(); }\n";
		compiler.update("Main.hx", program("boom"));
		var first = compiler.compile("Main"),
			live = Runtime.load(HlWriter.encode(first.module), first.runtimeIdentity),
			mainId = first.functionIds.get("main");
		var before = Runtime.callInt(live, mainId);
		if (before != 7)
			throw 'The exception stack is incomplete before any patch: $before';
		compiler.update("Main.hx", program("bang"));
		var changed = compiler.compile("Main");
		if (changed.requiresReload || changed.patchBytes == null)
			throw "Editing the thrown message did not produce a patch";
		Runtime.patchSet(live, new PatchSet(first.revision, changed.revision, changed.patchBytes, changed.changedFunctions));
		var after = Runtime.callInt(live, mainId);
		if (after != 7)
			throw 'The exception stack lost frames after a patch: $after';
		Runtime.dispose(live);
		Sys.println("PASS: exception stacks walk through patched code and the frames below it");
	}
}
