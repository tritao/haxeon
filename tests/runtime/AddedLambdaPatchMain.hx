import compiler.hl.HlWriter;
import compiler.Compiler;
import runtime.PatchSet;
import runtime.Runtime;

/**
 * Lambdas are named by where they are written, not by their position among the lambdas of their function, so an edit that adds
 * a lambda beside others patches the running module: closures it made before the edit keep their code, and an edited lambda
 * that captures the same variables updates in place, stored closures included.
 */
class AddedLambdaPatchMain {
	static function main():Void {
		var program = (extra:String, times:String) -> "class Panel {\n"
			+ "  public var handlers:Array<Int->Int> = [];\n"
			+ "  public function new() build();\n"
			+ "  function build():Void {\n"
			+ "    var scale = 3;\n"
			+ "    var inc = (x:Int) -> x + 1;\n"
			+ "    handlers.push(inc);\n"
			+ extra
			+ "    var times = (x:Int) -> " + times + ";\n"
			+ "    handlers.push(times);\n"
			+ "  }\n"
			+ "  public function run():Int {\n"
			+ "    var total = 0;\n"
			+ "    for (handler in handlers) total += handler(10);\n"
			+ "    return total;\n"
			+ "  }\n"
			+ "}\n"
			+ "class Holder { public static var panel:Null<Panel> = null; }\n"
			+ "function main():Int {\n"
			+ "  var kept = Holder.panel;\n"
			+ "  if (kept == null) { kept = new Panel(); Holder.panel = kept; }\n"
			+ "  return kept.run() * 100 + new Panel().run();\n"
			+ "}\n";
		var compiler = new Compiler();
		compiler.update("Main.hx", program("", "x * scale"));
		var build = compiler.compile("Main"),
			live = Runtime.load(HlWriter.encode(build.module), build.runtimeIdentity),
			mainId = build.functionIds.get("main");
		var before = Runtime.callInt(live, mainId);
		if (before != 4141)
			throw 'The program returned $before instead of 4141 before the edit';
		compiler.update("Main.hx", program("    var minus = (x:Int) -> x - 4;\n    handlers.push(minus);\n", "x * scale + 1"));
		var changed = compiler.compile("Main");
		if (changed.requiresReload || changed.patchBytes == null)
			throw 'Adding a lambda required a reload (requiresReload ${changed.requiresReload}, patch ${changed.patchBytes != null}): '
				+ [for (reason in changed.reloadReasons) Std.string(reason)].join(", ");
		Runtime.patchSet(live, new PatchSet(build.revision, changed.revision, changed.patchBytes, changed.changedFunctions));
		// The kept panel's two closures: 11, and the edited 31. A new panel: 11 + 6 + 31.
		var after = Runtime.callInt(live, mainId);
		if (after != 4248)
			throw 'The patched module returned $after instead of 4248';
		var fresh = Runtime.load(HlWriter.encode(changed.module), changed.runtimeIdentity);
		var clean = Runtime.callInt(fresh, changed.functionIds.get("main"));
		Runtime.dispose(fresh);
		if (clean != 4848)
			throw 'The full module returned $clean instead of 4848';
		Runtime.dispose(live);
		Sys.println("PASS: adding a lambda beside others patches the running module and keeps stored closures");
	}
}
