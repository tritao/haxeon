import compiler.hl.HlWriter;
import compiler.Compiler;
import runtime.PatchSet;
import runtime.Runtime;
import runtime.RuntimeError;
import runtime.RuntimeStatus;

/**
 * Closures the running program stored outlive the edit that changes or deletes their function:
 *
 * - A function whose signature changed leaves its old slot an adapter to the new code, when one can be built: a stored closure
 *   runs the new code with the defaults of the parameters it gained, across any number of edits (`HlModuleAssembler`).
 * - When none can be built (a required parameter was added), or the function was deleted, the patch names it as a guard and
 *   the runtime refuses the patch while a stored closure still reaches it, saying what holds it. A strict live host shows
 *   that refusal; the default host reloads instead. With no such closure the patch applies.
 */
class LiveClosureGuardMain {
	static function main():Void {
		adaptsStoredClosures();
		refusesIncompatibleSignatureWithStoredClosure();
		patchesIncompatibleSignatureWithoutStoredClosure();
		refusesDeletedStoredHandler();
		patchesDeletedHandlerNobodyStores();
		Sys.println("PASS: stored closures run adapted code, and a patch that would strand them is refused with what holds them");
	}

	/** A closure to `scale`, stored before two edits that each add a defaulted parameter, runs the latest code each time. */
	static function adaptsStoredClosures():Void {
		var versions = [
			"function scale(v:Int):Int return v * 2;\n",
			"function scale(v:Int, by:Int = 3):Int return v * by;\n",
			"function scale(v:Int, by:Int = 3, ?plus:Null<Int>):Int return v * by + (plus == null ? 1000 : plus);\n"
		];
		var session = start(storedScale(versions[0]));
		expect(Runtime.callInt(session.live, session.mainId), 8, "the stored closure before the edits");
		patch(session, storedScale(versions[1]), "a defaulted parameter added");
		expect(Runtime.callInt(session.live, session.mainId), 12, "the stored closure after a defaulted parameter was added");
		patch(session, storedScale(versions[2]), "a second defaulted parameter added");
		expect(Runtime.callInt(session.live, session.mainId), 1012, "the stored closure after two edits, through one adapter");
		Runtime.dispose(session.live);
	}

	static function refusesIncompatibleSignatureWithStoredClosure():Void {
		var session = start(storedScale("function scale(v:Int):Int return v * 2;\n"));
		expect(Runtime.callInt(session.live, session.mainId), 8, "the stored closure before the edit");
		var message = refused(session, storedScale("function scale(v:Int, by:Int):Int return v * by;\n", "scale(4, 2)"), "a required parameter added");
		mention(message, "Main.scale changed signature incompatibly", "the refusal");
		mention(message, "1 stored closure still references it", "the refusal");
		mention(message, "Holder.scaler", "the refusal");
		// Nothing applied: the stored closure still runs the code it had.
		expect(Runtime.callInt(session.live, session.mainId), 8, "the stored closure after the refused patch");
		Runtime.dispose(session.live);
	}

	static function patchesIncompatibleSignatureWithoutStoredClosure():Void {
		var program = (scale:String, call:String) -> scale + "function main():Int return " + call + ";\n";
		var session = start(program("function scale(v:Int):Int return v * 2;\n", "scale(4)"));
		expect(Runtime.callInt(session.live, session.mainId), 8, "before the edit");
		patch(session, program("function scale(v:Int, by:Int):Int return v * by;\n", "scale(4, 5)"), "a required parameter added, nothing stored");
		expect(Runtime.callInt(session.live, session.mainId), 20, "after a required parameter was added");
		Runtime.dispose(session.live);
	}

	static function refusesDeletedStoredHandler():Void {
		var session = start(handlers(["x -> x + 1", "x -> x * 10"], true));
		expect(Runtime.callInt(session.live, session.mainId), 2 * 100 + 10, "the stored handlers before the edit");
		var message = refused(session, handlers(["x -> x * 10"], true), "the first stored handler deleted");
		mention(message, "a deleted lambda at Main.hx:", "the refusal");
		mention(message, "Ui.handlers[0]", "the refusal");
		expect(Runtime.callInt(session.live, session.mainId), 2 * 100 + 10, "the stored handlers after the refused patch");
		Runtime.dispose(session.live);
	}

	static function patchesDeletedHandlerNobodyStores():Void {
		var session = start(handlers(["x -> x + 1", "x -> x * 10"], false));
		expect(Runtime.callInt(session.live, session.mainId), 2 * 100 + 10, "the handlers before the edit");
		patch(session, handlers(["x -> x * 10"], false), "a handler nobody stores deleted");
		expect(Runtime.callInt(session.live, session.mainId), 10, "the handlers after the edit");
		Runtime.dispose(session.live);
	}

	/** A program that stores a closure to `scale` once and calls it with 4. */
	static function storedScale(scale:String, ?direct:String):String
		return scale + "class Holder {\n  public static var scaler:Null<Int->Int> = null;\n}\n" + "function main():Int {\n"
			+ "  if (Holder.scaler == null) Holder.scaler = scale;\n" + "  var stored:Int->Int = Holder.scaler;\n"
			+ (direct == null ? "  return stored(4);\n" : "  return stored(4) + 0 * " + direct + ";\n") + "}\n";

	/** Handlers registered on each call (`stored` false) or once, kept in `Ui.handlers`, each run with 1. */
	static function handlers(bodies:Array<String>, stored:Bool):String {
		var pushes = [for (body in bodies) '    into.push($body);\n'].join("");
		return "class Ui {\n" + "  public static var handlers:Array<Int->Int> = [];\n" + "  public static function register(into:Array<Int->Int>):Void {\n"
			+ pushes + "  }\n" + "}\n" + "function main():Int {\n"
			+ (stored ? "  if (Ui.handlers.length == 0) Ui.register(Ui.handlers);\n  var list = Ui.handlers;\n" : "  var list:Array<Int->Int> = [];\n  Ui.register(list);\n")
			+ "  var value = 0;\n" + "  for (handler in list) value = value * 100 + handler(1);\n" + "  return value;\n" + "}\n";
	}

	static function start(source:String):{compiler:Compiler, build:Dynamic, live:runtime.LoadedModule, mainId:Int} {
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

	static function compileEdit(session:{compiler:Compiler, build:Dynamic, live:runtime.LoadedModule, mainId:Int}, source:String, label:String):Dynamic {
		session.compiler.update("Main.hx", source);
		var changed = session.compiler.compile("Main");
		if (changed.requiresReload || changed.patchBytes == null)
			throw '$label: required a reload: ${[for (reason in (changed.reloadReasons : Array<Dynamic>)) Std.string(reason)].join(", ")}';
		return changed;
	}

	static function patch(session:{compiler:Compiler, build:Dynamic, live:runtime.LoadedModule, mainId:Int}, source:String, label:String):Void {
		var changed = compileEdit(session, source, label);
		try
			Runtime.patchSet(session.live, new PatchSet(session.build.revision, changed.revision, changed.patchBytes, changed.changedFunctions))
		catch (error:RuntimeError)
			throw '$label: the runtime refused the patch: ${error.message}';
		session.build = changed;
		session.compiler.acknowledgePublication(changed.revision);
	}

	/** The edit compiles to a patch, which the runtime refuses because stored closures reach what it drops; its message. */
	static function refused(session:{compiler:Compiler, build:Dynamic, live:runtime.LoadedModule, mainId:Int}, source:String, label:String):String {
		var changed = compileEdit(session, source, label);
		try {
			Runtime.patchSet(session.live, new PatchSet(session.build.revision, changed.revision, changed.patchBytes, changed.changedFunctions));
		} catch (error:RuntimeError) {
			if (error.status != RuntimeStatus.ClosuresHeld)
				throw '$label: the runtime refused the patch for another reason: ${error.message}';
			return error.message;
		}
		throw '$label: the patch applied though a stored closure reaches what it drops';
	}

	static function mention(text:String, part:String, label:String):Void
		if (text.indexOf(part) < 0)
			throw '$label does not say "$part": $text';

	static function expect(actual:Int, expected:Int, label:String):Void
		if (actual != expected)
			throw '$label: the program returned $actual instead of $expected';
}
