import compiler.hl.HlWriter;
import compiler.Compiler;
import runtime.PatchSet;
import runtime.Runtime;

/**
 * A lambda is named by its position among the lambdas written at the same place, so inserting one before a sibling, deleting
 * one or reordering them renames the siblings after it (`register#into.push(1)#0` becomes `#1`). Such an edit patches: the
 * running module's lambdas are matched with the new build's by their code and renamed (`LambdaAlignment`), so each keeps its
 * slot and every closure the program stored keeps running its own function, or the edited version of it. An edit that
 * cannot be matched still reloads, because the generated functions were renumbered.
 */
class LambdaRenumberPatchMain {
	static final plain = [
		"plusOne" => "x + 1",
		"timesTen" => "x * 10",
		"timesTwenty" => "x * 20",
		"plusForty" => "x + 40"
	];

	/** The same handlers, each capturing `scale` (3), so every one has an environment named after the lambda. */
	static final capturing = [
		"plusOne" => "x + scale",
		"timesTen" => "x * scale * 10",
		"timesTwenty" => "x * scale * 20",
		"plusForty" => "x + scale + 40",
		"nested" => "apply(y -> y * x, scale + 1)",
		"nestedTwice" => "apply(y -> y * x * 2, scale + 1)"
	];

	static function main():Void {
		for (kind in [{name: "plain", bodies: plain}, {name: "capturing", bodies: capturing}]) {
			var source = (handlers:Array<String>) -> program(kind.bodies, handlers), label = kind.name;
			var plusOne = kind.bodies == plain ? 2 : 4, timesTen = kind.bodies == plain ? 10 : 30, timesTwenty = kind.bodies == plain ? 20 : 60,
				plusForty = kind.bodies == plain ? 41 : 44;
			// Stored handlers return plusOne and timesTen; a fresh registration runs every handler of the new source.
			var session = start(source(["plusOne", "timesTen"]), plusOne * 100 + timesTen);
			patch('$label: one inserted before its siblings', session, source(["plusForty", "plusOne", "timesTen"]), plusOne * 100 + timesTen,
				plusForty * 10000 + plusOne * 100 + timesTen);
			// The renamed lambdas are the running module's now: a later edit of one reaches the closures stored before.
			patch('$label: a renamed one edited afterwards', session, source(["plusForty", "plusOne", "timesTwenty"]), plusOne * 100 + timesTwenty,
				plusForty * 10000 + plusOne * 100 + timesTwenty);
			Runtime.dispose(session.live);
			session = start(source(["plusOne", "timesTen"]), plusOne * 100 + timesTen);
			patch('$label: one inserted before its siblings while a later one is edited', session, source(["plusForty", "plusOne", "timesTwenty"]),
				plusOne * 100 + timesTwenty, plusForty * 10000 + plusOne * 100 + timesTwenty);
			Runtime.dispose(session.live);
			session = start(source(["plusOne", "timesTen"]), plusOne * 100 + timesTen);
			patch('$label: the first one deleted', session, source(["timesTen"]), plusOne * 100 + timesTen, timesTen);
			Runtime.dispose(session.live);
			session = start(source(["plusOne", "timesTen"]), plusOne * 100 + timesTen);
			patch('$label: two swapped', session, source(["timesTen", "plusOne"]), plusOne * 100 + timesTen, timesTen * 100 + plusOne);
			Runtime.dispose(session.live);
			session = start(source(["plusOne", "timesTen"]), plusOne * 100 + timesTen);
			patch('$label: one inserted, one deleted', session, source(["plusForty", "plusOne"]), plusOne * 100 + timesTen,
				plusForty * 100 + plusOne);
			Runtime.dispose(session.live);
			// Both siblings changed: each could be an edit, or one inserted and the other deleted. Nothing tells which.
			session = start(source(["plusOne", "timesTen"]), plusOne * 100 + timesTen);
			refuse('$label: both edited', session, source(["plusForty", "timesTwenty"]));
			Runtime.dispose(session.live);
			// One inserted before a sibling that was edited too: the edited sibling could be either new lambda.
			session = start(source(["plusOne", "timesTen"]), plusOne * 100 + timesTen);
			refuse('$label: one inserted beside an edited one', session, source(["plusForty", "timesTwenty", "timesTen"]));
			Runtime.dispose(session.live);
		}
		// A lambda with a lambda in it: the inner one and its environment are named after the outer one, and move with it.
		var source = (handlers:Array<String>) -> program(capturing, handlers);
		var session = start(source(["nested", "timesTen"]), 4 * 100 + 30);
		patch("nested: one inserted before a lambda with a capturing lambda in it", session, source(["plusForty", "nested", "timesTen"]), 4 * 100
			+ 30, 44 * 10000 + 4 * 100 + 30);
		// The inner lambda moved with the outer one: editing it now reaches the stored outer closure, which makes it on each call.
		patch("nested: the moved inner lambda edited afterwards", session, source(["plusForty", "nestedTwice", "timesTen"]), 8 * 100 + 30,
			44 * 10000 + 8 * 100 + 30);
		Runtime.dispose(session.live);
		Sys.println("PASS: inserting, deleting and reordering lambdas at one anchor patches, and stored closures keep their functions");
	}

	static function program(bodies:Map<String, String>, handlers:Array<String>):String {
		var stored = [for (handler in handlers) '    into.push(x -> ${bodies.get(handler)});\n'].join("");
		return "class Ui {\n"
			+ "  public static var stored:Array<Int->Int> = [];\n"
			+ "  static function apply(f:Int->Int, value:Int):Int return f(value);\n"
			+ "  public static function register(into:Array<Int->Int>, scale:Int):Void {\n"
			+ stored
			+ "  }\n"
			+ "  public static function run(handlers:Array<Int->Int>):Int {\n"
			+ "    var value = 0;\n"
			+ "    for (handler in handlers) value = value * 100 + handler(1);\n"
			+ "    return value;\n"
			+ "  }\n"
			+ "}\n"
			+ "function main():Int {\n"
			+ "  if (Ui.stored.length == 0) Ui.register(Ui.stored, 3);\n"
			+ "  return Ui.run(Ui.stored);\n"
			+ "}\n";
	}

	static function start(source:String, expected:Int):{compiler:Compiler, build:Dynamic, live:runtime.LoadedModule, mainId:Int} {
		var compiler = new Compiler();
		compiler.update("Main.hx", source);
		var build = compiler.compile("Main");
		var session = {
			compiler: compiler,
			build: build,
			live: Runtime.load(HlWriter.encode(build.module), build.runtimeIdentity),
			mainId: build.functionIds.get("main")
		};
		var value = Runtime.callInt(session.live, session.mainId);
		if (value != expected)
			throw 'The program returned $value instead of $expected before the edit';
		return session;
	}

	/** The edit patches, the stored handlers return `stored`, and the full module, run afresh, returns `fresh`. */
	static function patch(label:String, session:{compiler:Compiler, build:Dynamic, live:runtime.LoadedModule, mainId:Int}, after:String, stored:Int,
			fresh:Int):Void {
		session.compiler.update("Main.hx", after);
		var changed = session.compiler.compile("Main");
		if (changed.requiresReload || changed.patchBytes == null)
			throw '$label: required a reload: ${[for (reason in changed.reloadReasons) Std.string(reason)].join(", ")}';
		Runtime.patchSet(session.live, new PatchSet(session.build.revision, changed.revision, changed.patchBytes, changed.changedFunctions));
		var now = Runtime.callInt(session.live, session.mainId);
		if (now != stored)
			throw '$label: stored handlers return $now instead of $stored';
		var clean = Runtime.load(HlWriter.encode(changed.module), changed.runtimeIdentity);
		var value = Runtime.callInt(clean, changed.functionIds.get("main"));
		Runtime.dispose(clean);
		if (value != fresh)
			throw '$label: the full module returned $value instead of $fresh';
		session.build = changed;
		Sys.println('$label: patched');
	}

	static function refuse(label:String, session:{compiler:Compiler, build:Dynamic, live:runtime.LoadedModule, mainId:Int}, after:String):Void {
		session.compiler.update("Main.hx", after);
		var changed = session.compiler.compile("Main");
		var reasons = [for (reason in changed.reloadReasons) Std.string(reason)];
		if (!changed.requiresReload && changed.patchBytes != null)
			throw '$label: patched, but nothing tells which function each name stands for';
		if (reasons.filter(reason -> StringTools.startsWith(reason, "GeneratedFunctionsRenumbered(")).length == 0)
			throw '$label: reloaded, but not because generated functions were renumbered: ${reasons.join(", ")}';
		Sys.println('$label: reloaded because generated functions were renumbered');
	}
}
