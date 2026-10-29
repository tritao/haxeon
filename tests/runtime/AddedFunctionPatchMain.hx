import compiler.hl.HlWriter;
import compiler.Compiler;
import runtime.PatchSet;
import runtime.Runtime;

/** An edit that adds functions patches the running module, and the added functions can be patched again later. */
class AddedFunctionPatchMain {
	static function main():Void {
		var program = (extra:String, use:String) -> "class Ui {\n"
			+ "  public static var handlers:Array<Int->Int> = [];\n"
			+ "  public static function register():Void { handlers.push(x -> x + 1); }\n"
			+ extra
			+ "}\n"
			+ "function main():Int {\n"
			+ "  if (Ui.handlers.length == 0) Ui.register();\n"
			+ "  return Ui.handlers[0](1)"
			+ use
			+ ";\n"
			+ "}\n";
		var compiler = new Compiler();
		compiler.update("Main.hx", program("", ""));
		var build = compiler.compile("Main"),
			live = Runtime.load(HlWriter.encode(build.module), build.runtimeIdentity),
			mainId = build.functionIds.get("main");
		if (Runtime.callInt(live, mainId) != 2)
			throw "The program did not run correctly before the edits";
		var edits = [
			{
				label: "a new static function, called directly and through a closure, and a new lambda",
				source: program("  public static function bonus(x:Int):Int return x * 7;\n",
					" + Ui.bonus(2) + { var f = Ui.bonus; f(1); } + { var extra = (y:Int) -> y + 100; extra(0); }"),
				// The stored handler still adds one: 2 + 14 + 7 + 100.
				expected: 123
			},
			{
				label: "an edit of the added function",
				source: program("  public static function bonus(x:Int):Int return x * 8;\n",
					" + Ui.bonus(2) + { var f = Ui.bonus; f(1); } + { var extra = (y:Int) -> y + 100; extra(0); }"),
				expected: 126
			}
		];
		for (edit in edits) {
			compiler.update("Main.hx", edit.source);
			var changed = compiler.compile("Main");
			if (changed.requiresReload || changed.patchBytes == null)
				throw '${edit.label} required a reload: ${[for (reason in changed.reloadReasons) Std.string(reason)].join(", ")}';
			Runtime.patchSet(live, new PatchSet(build.revision, changed.revision, changed.patchBytes, changed.changedFunctions));
			var result = Runtime.callInt(live, mainId);
			if (result != edit.expected)
				throw 'After ${edit.label} the patched module returned $result instead of ${edit.expected}';
			// A rejected patch falls back to loading the same build's full module, which must run on its own.
			var fresh = Runtime.load(HlWriter.encode(changed.module), changed.runtimeIdentity),
				reloaded = Runtime.callInt(fresh, changed.functionIds.get("main"));
			Runtime.dispose(fresh);
			if (reloaded != edit.expected)
				throw 'After ${edit.label} the full module returned $reloaded instead of ${edit.expected}';
			build = changed;
		}
		Runtime.dispose(live);
		Sys.println("PASS: edits that add functions patch the running module");
	}
}
