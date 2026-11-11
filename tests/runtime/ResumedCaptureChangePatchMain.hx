import compiler.hl.HlWriter;
import compiler.Compiler;
import runtime.PatchSet;
import runtime.Runtime;

/**
 * A live session that resumes the published module (`CompilerSession.resumeLiveModule`: a new compiler made from the published
 * history, `Compiler.exportIdentityState`) patches an edit that changes what a lambda captures, and one that deletes it.
 *
 * A lambda whose captures change is a new function with a new environment type (`LambdaName.withCaptures`); the old one stays
 * in the module for closures the running program may hold (`HlModuleAssembler.dropGuards`), and its environment is gone from
 * the program. A resident session reuses the old function's lowered code, but a resumed one has only its IR and lowers it
 * again, against the environment type the running module has. Before that, the resumed build failed with
 * `Unknown IR object "$lambda-env:..."` (the editor's live session after its minimap fix).
 */
class ResumedCaptureChangePatchMain {
	static function program(handler:String):String
		return "class Box { public var value:Int; public function new(value:Int) this.value = value; }\n"
			+ "class Pane {\n"
			+ "  public var handler:Null<Int->Int> = null;\n"
			+ "  public function new() {}\n"
			+ "  public function onResolved(callback:Int->Int):Void handler = callback;\n"
			+ "  public static function build(pane:Pane):Void {\n"
			+ "    var first = new Box(5);\n"
			+ "    var second = new Box(7);\n"
			+ "    var firstStyle = first;\n"
			+ handler
			+ "  }\n"
			+ "}\n"
			+ "function main():Int {\n"
			+ "  var pane = new Pane();\n"
			+ "  Pane.build(pane);\n"
			+ "  var handler = pane.handler;\n"
			+ "  return handler == null ? -1 : handler(10);\n"
			+ "}\n";

	static function capturing(body:String):String
		return program("    pane.onResolved(function(x) {\n      " + body + "\n    });\n");

	static function main():Void {
		var compiler = new Compiler();
		compiler.enablePublicationTracking();
		compiler.update("Main.hx", capturing("return x + firstStyle.value;"));
		var build = compiler.compile("Main");
		compiler.acknowledgePublication(build.revision);
		var live = Runtime.load(HlWriter.encode(build.module), build.runtimeIdentity),
			mainId = build.functionIds.get("main");
		var before = Runtime.callInt(live, mainId);
		if (before != 15)
			throw 'The program returned $before instead of 15 before the edit';
		// The live session stops, and the next one resumes from the history it left beside the module.
		var resumed = new Compiler(compiler.exportIdentityState());
		resumed.update("Main.hx", capturing("return x + first.value + second.value;"));
		var changed = patch(resumed, live, build.revision, "capture change");
		check(live, mainId, 22, "capture change");
		// Resumed again: the lambda is deleted, and the module keeps both earlier versions of it.
		resumed.acknowledgePublication(changed.revision);
		var again = new Compiler(resumed.exportIdentityState());
		again.update("Main.hx", program(""));
		patch(again, live, changed.revision, "deletion");
		check(live, mainId, -1, "deletion");
		Runtime.dispose(live);
		Sys.println("PASS: a resumed live compiler patches a lambda whose captures changed, and its deletion");
	}

	static function patch(compiler:Compiler, live:runtime.LoadedModule, baseRevision:Int, label:String) {
		var result = compiler.compile("Main");
		if (result.requiresReload || result.patchBytes == null)
			throw 'The resumed $label did not patch (requiresReload ${result.requiresReload}, patch ${result.patchBytes != null}): '
				+ [for (reason in result.reloadReasons) Std.string(reason)].join(", ");
		Runtime.patchSet(live, new PatchSet(baseRevision, result.revision, result.patchBytes, result.changedFunctions));
		return result;
	}

	static function check(live:runtime.LoadedModule, mainId:Int, expected:Int, label:String):Void {
		var actual = Runtime.callInt(live, mainId);
		if (actual != expected)
			throw 'After the resumed $label the patched module returned $actual instead of $expected';
	}
}
