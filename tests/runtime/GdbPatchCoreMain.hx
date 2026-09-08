import compiler.Compiler;
import compiler.hl.HlWriter;
import runtime.PatchSet;
import runtime.Runtime;

class GdbPatchCoreMain {
	static function main():Void {
		var compiler = new Compiler();
		compiler.update("PatchCrash.hx", '@:hlNative("patch_core") extern class PatchCrash { static function fault(address:Int):Void; }');
		compiler.update("CrashPoint.hx", "function run():Int { PatchCrash.fault(0); return 42; }");
		compiler.update("Main.hx", "function main():Int { return CrashPoint.run(); }");
		var initial = compiler.compile("Main"),
			live = Runtime.load(HlWriter.encode(initial.module), initial.runtimeIdentity),
			runId = initial.functionIds.get("CrashPoint.run");
		if (Runtime.callInt(live, runId) != 42)
			throw "initial crash probe returned the wrong value";
		var generationOneSource = [for (_ in 0...8) ""].join("\n") + "\nfunction run():Int { PatchCrash.fault(0); return 43; }";
		compiler.update("CrashPoint.hx", generationOneSource);
		var generationOne = compiler.compile("Main");
		if (generationOne.requiresReload || generationOne.patchBytes == null)
			throw "first crash probe edit did not produce a hot patch";
		Runtime.patchSet(live, new PatchSet(initial.revision, generationOne.revision, generationOne.patchBytes, generationOne.changedFunctions));
		if (Runtime.callInt(live, runId) != 43)
			throw "first crash probe patch returned the wrong value";
		var generationTwoSource = [for (_ in 0...16) ""].join("\n") + "\nfunction run():Int { PatchCrash.fault(1); return 44; }";
		compiler.update("CrashPoint.hx", generationTwoSource);
		var generationTwo = compiler.compile("Main");
		if (generationTwo.requiresReload || generationTwo.patchBytes == null)
			throw "second crash probe edit did not produce a hot patch";
		Runtime.patchSet(live, new PatchSet(generationOne.revision, generationTwo.revision, generationTwo.patchBytes, generationTwo.changedFunctions));
		Runtime.callInt(live, runId);
	}
}
