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
		compiler.update("CrashPoint.hx", "function run():Int { PatchCrash.fault(1); return 43; }");
		var changed = compiler.compile("Main");
		if (changed.requiresReload || changed.patchBytes == null)
			throw "crash probe did not produce a hot patch";
		Runtime.patchSet(live, new PatchSet(initial.revision, changed.revision, changed.patchBytes, changed.changedFunctions));
		Runtime.callInt(live, runId);
	}
}
