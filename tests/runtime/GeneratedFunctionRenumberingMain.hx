import compiler.hl.HlWriter;
import compiler.Compiler;
import runtime.PatchSet;
import runtime.Runtime;

/**
 * Lambdas and function adapters are named by their position among their siblings. A patch replaces the code under each name,
 * and closures the running program already stored keep calling that name. When an edit renumbers the siblings, a name can
 * stand for a different function than before. A stored closure must never silently run another function's code: such an
 * edit either patches only when every stored closure keeps its behaviour, or reloads because the functions were renumbered.
 *
 * A lambda's code is its body, so moving names between lambdas changes what stored closures run and must reload. A function
 * adapter keeps the function it wraps in its closure, and its code only converts the signature: adapters of one signature
 * share their code, so their names can move without changing any stored closure, and the edit may patch.
 */
class GeneratedFunctionRenumberingMain {
	static function main():Void {
		// Each handler is stored as a lambda, or as an adapter that turns a typed function into a Dynamic one.
		var lambdas = (handlers:Array<String>) -> program("Array<Int->Int>", handlers);
		var adapters = (handlers:Array<String>) -> program("Array<Dynamic->Dynamic>", [for (handler in handlers) "Ui." + handler]);
		// Stored handlers run their own functions: 2 * 100 + 10.
		for (kind in [{name: "lambda", source: lambdas}, {name: "adapter", source: adapters}]) {
			var source = kind.source, original = ["plusOne", "timesTen"];
			expectStoredBehaviour('${kind.name}: one inserted above the stored ones while a later one is deleted', source(original),
				source(["minusFive", "plusOne"]), 210);
			expectStoredBehaviour('${kind.name}s swapped', source(original), source(["timesTen", "plusOne"]), 210);
			// Only the last one changed, but it now matches the ones above it: it was either edited, or a copy was inserted above
			// and the last one deleted. Nothing tells which function its name stands for.
			expectStoredBehaviour('${kind.name}: the last one turned into a copy of the ones above it', source(["plusOne", "plusOne", "timesTen"]),
				source(["plusOne", "plusOne", "plusOne"]), 202);
		}
		// Editing a lambda in place reaches the closures already stored. An adapter's stored closure keeps the function it was
		// made from; the edit changes which function later registrations wrap.
		expectPatch("lambda: one edited in place", lambdas(["plusOne", "timesTen"]), lambdas(["plusOne", "timesTwenty"]), 220);
		expectPatch("adapter: one edited in place", adapters(["plusOne", "timesTen"]), adapters(["plusOne", "timesTwenty"]), 210);
		Sys.println("PASS: edits that renumber lambdas or function adapters never reroute stored closures");
	}

	static final bodies = [
		"plusOne" => "x + 1",
		"timesTen" => "x * 10",
		"timesTwenty" => "x * 20",
		"minusFive" => "x - 5"
	];

	/** A lambda handler is written inline; `Ui.<name>` stores a typed function, which the handler type makes an adapter. */
	static function program(handlerType:String, handlers:Array<String>):String {
		var stored = [
			for (handler in handlers)
				'    handlers.push(${StringTools.startsWith(handler, "Ui.") ? handler : "x -> " + bodies.get(handler)});\n'
		].join("");
		return "class Ui {\n" + '  public static var handlers:$handlerType = [];\n' + [
			for (name => body in bodies)
				'  public static function $name(x:Int):Int return $body;\n'
		].join("")
			+ "  public static function register():Void {\n"
			+ stored
			+ "  }\n"
			+ "}\n"
			+ "function main():Int {\n"
			+ "  if (Ui.handlers.length == 0) Ui.register();\n"
			+ "  var first:Int = Ui.handlers[0](1);\n"
			+ "  var second:Int = Ui.handlers[1](1);\n"
			+ "  return first * 100 + second;\n"
			+ "}\n";
	}

	static function start(source:String):{
		compiler:Compiler,
		build:Dynamic,
		live:runtime.LoadedModule,
		mainId:Int
	} {
		var compiler = new Compiler();
		compiler.update("Main.hx", source);
		var build = compiler.compile("Main");
		return {
			compiler: compiler,
			build: build,
			live: Runtime.load(HlWriter.encode(build.module), build.runtimeIdentity),
			mainId: build.functionIds.get("main")
		};
	}

	/**
	 * Either the patch keeps every stored closure's behaviour, or the runtime refuses it because a stored closure reaches a
	 * function it drops, or the edit reloads because generated functions were renumbered.
	 */
	static function expectStoredBehaviour(label:String, before:String, after:String, stored:Int):Void {
		var session = start(before);
		if (Runtime.callInt(session.live, session.mainId) != stored)
			throw '$label: the program did not run correctly before the edit';
		session.compiler.update("Main.hx", after);
		var changed = session.compiler.compile("Main");
		if (!changed.requiresReload && changed.patchBytes != null) {
			var refusal:Null<String> = null;
			try
				Runtime.patchSet(session.live, new PatchSet(session.build.revision, changed.revision, changed.patchBytes, changed.changedFunctions))
			catch (error:runtime.RuntimeError) {
				if (error.status != runtime.RuntimeStatus.ClosuresHeld)
					throw error;
				refusal = error.message;
			}
			var now = Runtime.callInt(session.live, session.mainId);
			if (now != stored)
				throw '$label: the edit was offered as a patch, and stored handlers now return $now instead of $stored';
			Sys.println(refusal == null ? '$label: patched; stored handlers kept their behaviour' : '$label: refused; $refusal');
		} else {
			var reasons = [for (reason in changed.reloadReasons) Std.string(reason)];
			if (reasons.filter(reason -> StringTools.startsWith(reason, "GeneratedFunctionsRenumbered(")).length == 0)
				throw '$label: reloaded, but not because generated functions were renumbered: ${reasons.join(", ")}';
			Sys.println('$label: reloaded because generated functions were renumbered');
		}
		Runtime.dispose(session.live);
	}

	static function expectPatch(label:String, before:String, after:String, expected:Int):Void {
		var session = start(before);
		Runtime.callInt(session.live, session.mainId);
		session.compiler.update("Main.hx", after);
		var changed = session.compiler.compile("Main");
		if (changed.requiresReload || changed.patchBytes == null)
			throw '$label: required a reload: ${[for (reason in changed.reloadReasons) Std.string(reason)].join(", ")}';
		Runtime.patchSet(session.live, new PatchSet(session.build.revision, changed.revision, changed.patchBytes, changed.changedFunctions));
		if (Runtime.callInt(session.live, session.mainId) != expected)
			throw '$label: stored handlers did not run the edited code';
		Runtime.dispose(session.live);
	}
}
