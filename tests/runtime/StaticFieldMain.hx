using compiler.compilation.BackendArtifact.BackendArtifacts;
import compiler.Compiler;
import compiler.hl.HlWriter;
import runtime.PatchSet;
import runtime.Runtime;

class StaticFieldMain {
	static function main():Void {
		var compiler = new Compiler();
		compiler.update("Main.hx",
			"class Counter { public static var value:Int = 40; public static function bump():Int { value++; return value; } } function main():Int { return Counter.bump(); }");
		var first = compiler.compile("Main"),
			live = Runtime.load(HlWriter.encode(first.artifact.hashLink().module).flatten(),
				first.artifact.hashLink().runtimeIdentity),
			mainId = first.artifact.hashLink().functionIds.get("main");
		if (Runtime.callInt(live, mainId) != 41)
			throw "Static field initializer did not run before the first call";
		compiler.update("Main.hx",
			"class Counter { public static var value:Int = 40; public static function bump():Int { value++; value++; return value; } } function main():Int { return Counter.bump(); }");
		var changed = compiler.compile("Main");
		if (changed.requiresReload || changed.artifact.hashLink().patchBytes == null)
			throw "Static field body edit did not produce a compatible patch";
		Runtime.patchSet(live,
			new PatchSet(first.revision, changed.revision, changed.artifact.hashLink().patchBytes,
			changed.changedFunctions));
		if (Runtime.callInt(live, mainId) != 43)
			throw "Static global state was not retained across a body patch";
		Runtime.dispose(live);
		Sys.println("PASS: static fields lower to persistent HashLink globals");
	}
}
