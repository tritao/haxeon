import compiler.hl.HlWriter;
import compiler.Compiler;
import runtime.PatchSet;
import runtime.Runtime;

/**
 * Lambdas, and the cells of the locals they capture, keep their names when code around them moves, so edits that add lines
 * still patch the running module.
 */
class StableLambdaPatchMain {
	static function main():Void {
		var compiler = new Compiler();
		var program = (firstPrefix:String, secondPrefix:String, factor:Int) -> "class Ui {\n"
			+ "  public static function first():Int {\n"
			+ firstPrefix
			+ "    var add = (x:Int) -> x + 1;\n"
			+ "    return add(1);\n"
			+ "  }\n"
			+ "  public static function second():Int {\n"
			+ secondPrefix
			+ "    var total = 0;\n"
			+ "    var scale = (x:Int) -> { total += x; return x * "
			+ factor
			+ "; };\n"
			+ "    return scale(3) + total;\n"
			+ "  }\n"
			+ "}\n"
			+ "function main():Int { return Ui.first() * 100 + Ui.second(); }\n";
		compiler.update("Main.hx", program("", "", 2));
		var build = compiler.compile("Main"),
			live = Runtime.load(HlWriter.encode(build.module), build.runtimeIdentity),
			mainId = build.functionIds.get("main");
		if (Runtime.callInt(live, mainId) != 209)
			throw "The program did not run correctly before the edits";
		var edits = [
			{
				label: "new lines above a lambda, which move every lambda after them",
				source: program("    var padding = 0;\n    padding++;\n", "", 3),
				expected: 212
			},
			{
				label: "new lines in a second function",
				source: program("    var padding = 0;\n    padding++;\n", "    var unused = 1;\n    unused += 2;\n", 4),
				expected: 215
			}
		];
		for (edit in edits) {
			compiler.update("Main.hx", edit.source);
			var changed = compiler.compile("Main");
			if (changed.requiresReload || changed.patchBytes == null)
				throw 'Adding ${edit.label} required a reload: ${[for (reason in changed.reloadReasons) Std.string(reason)].join(", ")}';
			Runtime.patchSet(live, new PatchSet(build.revision, changed.revision, changed.patchBytes, changed.changedFunctions));
			if (Runtime.callInt(live, mainId) != edit.expected)
				throw 'After ${edit.label} the patched module did not run the edited code';
			build = changed;
		}
		Runtime.dispose(live);
		Sys.println("PASS: lambdas keep their names when code around them moves");
	}
}
