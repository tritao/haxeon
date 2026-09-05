import compiler.hl.HlWriter;
import compiler.modules.Compiler;
import runtime.PatchSet;
import runtime.Runtime;

class StaticFieldMain {
	static function main():Void {
		var compiler = new Compiler();
		compiler.update("Main.hx",
			"class Counter { public static var value:Int; public static function bump():Int { value++; return value; } } function main():Int { return Counter.bump(); }");
		var first = compiler.compile("Main"),
			live = Runtime.load(HlWriter.encode(first.module), first.runtimeIdentity),
			mainId = first.functionIds.get("main");
		if (Runtime.callInt(live, mainId) != 1)
			throw "Static field did not retain its initial global value";
		compiler.update("Main.hx",
			"class Counter { public static var value:Int; public static function bump():Int { value++; value++; return value; } } function main():Int { return Counter.bump(); }");
		var changed = compiler.compile("Main");
		if (changed.requiresReload || changed.patchBytes == null)
			throw "Static field body edit did not produce a compatible patch";
		Runtime.patchSet(live, new PatchSet(first.revision, changed.revision, changed.patchBytes, changed.changedFunctions, false));
		if (Runtime.callInt(live, mainId) != 3)
			throw "Static global state was not retained across a body patch";
		Runtime.dispose(live);
		Sys.println("PASS: static fields lower to persistent HashLink globals");
	}
}
