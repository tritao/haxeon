import compiler.hl.HlWriter;
import compiler.Compiler;
import compiler.runtime.CompilerIntrinsics;
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
		patchesDeletedHandlerTheUiRebuilds();
		rebuildsAfterAThrowingRelease();
		rebuildsWithoutReleasingAfterAnUnguardedPatch();
		refusesDeletingAHandlerAPatchStored();
		refusesDeletingManyStoredHandlers();
		refusesDeletingAHandlerANativeRootHolds();
		refusesDeletingAHandlerAThreadHolds();
		Sys.println("PASS: stored closures run adapted code, and a patch that would strand them is refused with what holds them");
	}

	/** A closure to `scale`, stored before two edits that each add a defaulted parameter, runs the latest code each time. */
	static function adaptsStoredClosures():Void {
		var versions = [
			"function scale(v:Int):Int return v * 2;\n",
			"function scale(v:Int, by:Int = 3):Int return v * by;\n",
			"function scale(v:Int, by:Int = 3, ?plus:Null<Int>):Int return v * by + (plus == null ? 1000 : plus);\n"
		];
		// Once `scale` has optional parameters it is no `Int->Int`: the edited source stores a lambda instead, but the closure
		// stored at the start is the one that keeps running.
		var session = start(storedScale(versions[0]));
		expect(Runtime.callInt(session.live, session.mainId), 8, "the stored closure before the edits");
		patch(session, storedScale(versions[1], "v -> scale(v)"), "a defaulted parameter added");
		expect(Runtime.callInt(session.live, session.mainId), 12, "the stored closure after a defaulted parameter was added");
		patch(session, storedScale(versions[2], "v -> scale(v)"), "a second defaulted parameter added");
		expect(Runtime.callInt(session.live, session.mainId), 1012, "the stored closure after two edits, through one adapter");
		Runtime.dispose(session.live);
	}

	static function refusesIncompatibleSignatureWithStoredClosure():Void {
		var session = start(storedScale("function scale(v:Int):Int return v * 2;\n"));
		expect(Runtime.callInt(session.live, session.mainId), 8, "the stored closure before the edit");
		var message = refused(session, storedScale("function scale(v:Int, by:Int):Int return v * by;\n", "v -> scale(v, 2)"),
			"a required parameter added");
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

	/**
	 * A handler only the UI holds, which the app rebuilds around a patch (`liveRelease`, `liveRebuild`): deleting it patches,
	 * and the rebuilt UI runs the new handlers. The same edit without letting go first is refused.
	 */
	static function patchesDeletedHandlerTheUiRebuilds():Void {
		var ui = (bodies:Array<String>) -> "class Ui {\n  public static var handlers:Array<Int->Int> = [];\n"
			+ "  public static function build():Void {\n" + [for (body in bodies) '    handlers.push($body);\n'].join("") + "  }\n}\n"
			+ "function liveRelease():Void Ui.handlers = [];\n" + "function liveRebuild():Void Ui.build();\n" + "function main():Int {\n"
			+ "  if (Ui.handlers.length == 0) Ui.build();\n" + "  var value = 0;\n" + "  for (handler in Ui.handlers) value = value * 100 + handler(1);\n"
			+ "  return value;\n}\n";
		var session = start(ui(["x -> x + 1", "x -> x * 10"]));
		expect(Runtime.callInt(session.live, session.mainId), 2 * 100 + 10, "the UI's handlers before the edit");
		var changed = compileEdit(session, ui(["x -> x * 10"]), "a handler the UI holds deleted");
		var patch = new PatchSet(session.build.revision, changed.revision, changed.patchBytes, changed.changedFunctions);
		// Without letting go first, the UI's closure strands the patch.
		try {
			Runtime.patchSet(session.live, patch);
			throw 'the patch applied though the UI still held the deleted handler';
		} catch (error:RuntimeError) {
			if (error.status != RuntimeStatus.ClosuresHeld)
				throw 'the patch was refused for another reason: ${error.message}';
			mention(error.message, "Ui.handlers[0]", "the refusal without the rebuild hooks");
		}
		Runtime.patchSetRebuilding(session.live, patch, changed.functionIds.get("Main.liveRelease"), changed.functionIds.get("Main.liveRebuild"),
			(_, error) -> throw 'a rebuild hook threw: $error');
		expect(Runtime.callInt(session.live, session.mainId), 10, "the rebuilt UI's handlers after the edit");
		Runtime.dispose(session.live);
	}

	/**
	 * A `liveRelease` that throws before letting go of anything: the patch is still tried, and refused, since the UI still
	 * holds the deleted handler; `liveRebuild` runs anyway, so the UI is not left released. What is thrown is the patch's
	 * refusal; the hook's error goes to `hookFailed`.
	 */
	static function rebuildsAfterAThrowingRelease():Void {
		var ui = (bodies:Array<String>) -> "class Ui {\n  public static var handlers:Array<Int->Int> = [];\n  public static var rebuilds = 0;\n"
			+ "  public static function build():Void {\n    handlers = [];\n" + [for (body in bodies) '    handlers.push($body);\n'].join("")
			+ "  }\n}\n" + "function liveRelease():Void throw \"release failed\";\n"
			+ "function liveRebuild():Void {\n  Ui.rebuilds++;\n  Ui.build();\n}\n" + "function main():Int {\n"
			+ "  if (Ui.handlers.length == 0) Ui.build();\n" + "  var value = Ui.rebuilds;\n"
			+ "  for (handler in Ui.handlers) value = value * 100 + handler(1);\n" + "  return value;\n}\n";
		var session = start(ui(["x -> x + 1", "x -> x * 10"]));
		expect(Runtime.callInt(session.live, session.mainId), 2 * 100 + 10, "the UI's handlers before the edit");
		var changed = compileEdit(session, ui(["x -> x * 10"]), "a handler the UI holds deleted");
		var hookErrors:Array<String> = [];
		try {
			Runtime.patchSetRebuilding(session.live, new PatchSet(session.build.revision, changed.revision, changed.patchBytes, changed.changedFunctions),
				changed.functionIds.get("Main.liveRelease"), changed.functionIds.get("Main.liveRebuild"),
				(rebuilding, error) -> hookErrors.push((rebuilding ? "rebuild: " : "release: ") + error));
			throw 'the patch applied though the UI still held the deleted handler';
		} catch (error:RuntimeError) {
			if (error.status != RuntimeStatus.ClosuresHeld)
				throw 'the patch was refused for another reason: ${error.message}';
		}
		if (hookErrors.length != 1 || hookErrors[0].indexOf("release: ") != 0)
			throw 'the throwing release was not reported once as a hook error: $hookErrors';
		// The old code still runs, and `liveRebuild` ran once: the UI holds both handlers again.
		expect(Runtime.callInt(session.live, session.mainId), (1 * 100 + 2) * 100 + 10, "the UI after the refused patch");
		Runtime.dispose(session.live);
	}

	/**
	 * A patch that drops nothing (a handler's body edited) has no guards: the app is not asked to let go of its UI, but it
	 * is asked to rebuild, so the new code shows without waiting for input.
	 */
	static function rebuildsWithoutReleasingAfterAnUnguardedPatch():Void {
		var ui = (body:String) -> "class Ui {
  public static var handlers:Array<Int->Int> = [];
"
			+ "  public static var releases = 0;
  public static var rebuilds = 0;
"
			+ "  public static function build():Void {
    handlers = [];
" + '    handlers.push($body);
' + "  }
}
"
			+ "function liveRelease():Void {
  Ui.releases++;
  Ui.handlers = [];
}
"
			+ "function liveRebuild():Void {
  Ui.rebuilds++;
  Ui.build();
}
" + "function main():Int {
"
			+ "  if (Ui.handlers.length == 0) Ui.build();
" + "  return Ui.releases * 1000 + Ui.rebuilds * 100 + Ui.handlers[0](1);
}
";
		var session = start(ui("x -> x + 1"));
		expect(Runtime.callInt(session.live, session.mainId), 2, "the UI before the edit");
		var changed = compileEdit(session, ui("x -> x + 5"), "a handler's body edited");
		var patch = new PatchSet(session.build.revision, changed.revision, changed.patchBytes, changed.changedFunctions);
		if (patch.hasGuards())
			throw 'editing a handler body produced a patch with guards';
		Runtime.patchSetRebuilding(session.live, patch, changed.functionIds.get("Main.liveRelease"), changed.functionIds.get("Main.liveRebuild"),
			(_, error) -> throw 'a rebuild hook threw: $error');
		expect(Runtime.callInt(session.live, session.mainId), 100 + 6, "no release, one rebuild, and the new body");
		Runtime.dispose(session.live);
	}

	/**
	 * A handler a patch starts storing (`Button.onClick = handleClick` added by an edit), which a later edit deletes: the
	 * patch is refused while the field holds it.
	 */
	static function refusesDeletingAHandlerAPatchStored():Void {
		var button = "class Button {\n  public static var onClick:Null<Int->Int> = null;\n}\n",
			click = "function click():Int {\n  var handler = Button.onClick;\n  return handler == null ? -1 : handler(1);\n}\n";
		var session = start(button + click + "function main():Int return click();\n");
		expect(Runtime.callInt(session.live, session.mainId), -1, "before any handler");
		patch(session, button + click + "function handleClick(x:Int):Int return x + 41;\n"
			+ "function main():Int {\n  if (Button.onClick == null) Button.onClick = handleClick;\n  return click();\n}\n", "a stored handler added");
		expect(Runtime.callInt(session.live, session.mainId), 42, "the handler the patch stored");
		var message = refused(session, button + click + "function main():Int return click();\n", "the stored handler deleted");
		mention(message, "handleClick", "the refusal");
		mention(message, "Button.onClick", "the refusal");
		expect(Runtime.callInt(session.live, session.mainId), 42, "the stored handler after the refused patch");
		Runtime.dispose(session.live);
	}

	/**
	 * More stored handlers than the module's first list of static closures holds (64): 70 the module stores from its first
	 * code, 40 more a patch stores. Deleting either kind is refused; deleting one nobody stores patches.
	 */
	static function refusesDeletingManyStoredHandlers():Void {
		// h0...h69 stored by the module's first code, h70...h109 by a patch's; `deleted` is left out, and pushed nowhere.
		function program(count:Int, deleted:Int, unused:Bool):String {
			var source = "class Ui {
  public static var handlers:Array<Int->Int> = [];
  public static var extra:Array<Int->Int> = [];
}
";
			for (i in 0...count)
				if (i != deleted)
					source += 'function h$i(x:Int):Int return x + $i;
';
			if (unused)
				source += "function unused(x:Int):Int return x;
";
			source += "function main():Int {
  if (Ui.handlers.length == 0) {
";
			for (i in 0...70)
				if (i != deleted)
					source += '    Ui.handlers.push(h$i);
';
			source += "  }
";
			if (count > 70) {
				source += "  if (Ui.extra.length == 0) {
";
				for (i in 70...count)
					if (i != deleted)
						source += '    Ui.extra.push(h$i);
';
				source += "  }
";
			}
			return source + "  var total = 0;
  for (handler in Ui.handlers) total += handler(1);
"
				+ "  for (handler in Ui.extra) total += handler(1);
  return total;
}
";
		}
		function sum(count:Int):Int {
			var total = 0;
			for (i in 0...count)
				total += i + 1;
			return total;
		}
		// A refused edit stays the compiler's last build, so each refusal gets a session of its own.
		function stored():{compiler:Compiler, build:Dynamic, live:runtime.LoadedModule, mainId:Int} {
			var session = start(program(70, -1, true));
			expect(Runtime.callInt(session.live, session.mainId), sum(70), "the 70 handlers the module stores");
			patch(session, program(110, -1, true), "40 stored handlers added");
			expect(Runtime.callInt(session.live, session.mainId), sum(110), "the 110 stored handlers");
			return session;
		}
		var session = stored();
		var message = refused(session, program(110, 69, true), "the last handler the module stored deleted");
		mention(message, "h69", "the refusal");
		mention(message, "Ui.handlers[69]", "the refusal");
		Runtime.dispose(session.live);
		session = stored();
		patch(session, program(110, -1, false), "a handler nobody stores deleted");
		expect(Runtime.callInt(session.live, session.mainId), sum(110), "the stored handlers after the edit");
		message = refused(session, program(110, 109, false), "the last handler the patch stored deleted");
		mention(message, "h109", "the refusal");
		mention(message, "Ui.extra[39]", "the refusal");
		Runtime.dispose(session.live);
	}

	/**
	 * A handler only a native root holds: deleting it is refused. HashLink's thread-local storage keeps its value in a root
	 * (`hl_tls_set`), as a native UI callback would.
	 */
	static function refusesDeletingAHandlerANativeRootHolds():Void {
		var holder = "@:hlNative(\"std\", \"tls_alloc\") extern function tlsAlloc(gcValue:Bool):hl.Abstract<\"hl_tls\">;\n"
			+ "@:hlNative(\"std\", \"tls_get\") extern function tlsGet(tls:hl.Abstract<\"hl_tls\">):Dynamic;\n"
			+ "@:hlNative(\"std\", \"tls_set\") extern function tlsSet(tls:hl.Abstract<\"hl_tls\">, value:Dynamic):Void;\n"
			+ "class Holder {\n  public static var local:hl.Abstract<\"hl_tls\"> = tlsAlloc(true);\n}\n";
		var session = start(holder + "function handleKey(x:Int):Int return x * 3;\n" + "function main():Int {\n"
			+ "  if (tlsGet(Holder.local) == null) tlsSet(Holder.local, handleKey);\n  var handler:Int->Int = tlsGet(Holder.local);\n"
			+ "  return handler(2);\n}\n");
		expect(Runtime.callInt(session.live, session.mainId), 6, "the handler thread-local storage holds");
		var message = refused(session, holder + "function main():Int return tlsGet(Holder.local) == null ? -1 : 0;\n", "the handler deleted");
		mention(message, "handleKey", "the refusal");
		mention(message, "held by a native root", "the refusal");
		expect(Runtime.callInt(session.live, session.mainId), 6, "the handler after the refused patch");
		Runtime.dispose(session.live);
	}

	/** A handler only a waiting thread's local holds: deleting it is refused while the thread runs, and patches once it ended. */
	static function refusesDeletingAHandlerAThreadHolds():Void {
		function program(handler:Bool):String
			return "import sys.thread.Thread;\n" + "class Work {\n  public static var ready = false;\n  public static var stop = false;\n"
				+ "  public static var finished = false;\n  public static var result = 0;\n}\n"
				+ (handler ? "function handleTick(x:Int):Int return x + 5;\n" : "")
				+ "function start():Int {\n  Thread.create(function() {\n"
				+ (handler ? "    var held:Int->Int = handleTick;\n" : "")
				+ "    Work.ready = true;\n    while (!Work.stop) Sys.sleep(0.001);\n"
				+ (handler ? "    Work.result = held(1);\n" : "")
				+ "    Work.finished = true;\n  });\n  while (!Work.ready) Sys.sleep(0.001);\n  return 0;\n}\n"
				+ "function finish():Int {\n  Work.stop = true;\n  while (!Work.finished) Sys.sleep(0.001);\n  return Work.result;\n}\n"
				+ "function main():Int return 0;\n";
		var session = start(program(true), true);
		var finish:Int = session.build.functionIds.get("Main.finish");
		expect(Runtime.callInt(session.live, session.build.functionIds.get("Main.start")), 0, "starting the thread");
		var changed = compileEdit(session, program(false), "the handler a thread holds deleted");
		var edit = new PatchSet(session.build.revision, changed.revision, changed.patchBytes, changed.changedFunctions);
		try {
			Runtime.patchSet(session.live, edit);
			throw 'the patch applied though a running thread held the deleted handler';
		} catch (error:RuntimeError) {
			if (error.status != RuntimeStatus.ClosuresHeld)
				throw 'the patch was refused for another reason: ${error.message}';
			mention(error.message, "handleTick", "the refusal");
			mention(error.message, "held by a running thread", "the refusal");
		}
		expect(Runtime.callInt(session.live, finish), 6, "the thread's handler after the refused patch");
		try
			Runtime.patchSet(session.live, edit)
		catch (error:RuntimeError)
			throw 'the patch was refused once the thread ended: ${error.message}';
		Runtime.dispose(session.live);
	}

	/** A program that stores `store`, a closure to `scale` by default, once and calls it with 4. */
	static function storedScale(scale:String, store:String = "scale"):String
		return scale + "class Holder {\n  public static var scaler:Null<Int->Int> = null;\n}\n" + "function main():Int {\n"
			+ "  if (Holder.scaler == null) Holder.scaler = " + store + ";\n" + "  var stored:Int->Int = Holder.scaler;\n" + "  return stored(4);\n"
			+ "}\n";

	/** Handlers registered on each call (`stored` false) or once, kept in `Ui.handlers`, each run with 1. */
	static function handlers(bodies:Array<String>, stored:Bool):String {
		var pushes = [for (body in bodies) '    into.push($body);\n'].join("");
		return "class Ui {\n" + "  public static var handlers:Array<Int->Int> = [];\n" + "  public static function register(into:Array<Int->Int>):Void {\n"
			+ pushes + "  }\n" + "}\n" + "function main():Int {\n"
			+ (stored ? "  if (Ui.handlers.length == 0) Ui.register(Ui.handlers);\n  var list = Ui.handlers;\n" : "  var list:Array<Int->Int> = [];\n  Ui.register(list);\n")
			+ "  var value = 0;\n" + "  for (handler in list) value = value * 100 + handler(1);\n" + "  return value;\n" + "}\n";
	}

	/** The program `source` compiled and loaded; `stdlib` lets it use the standard library (`Sys`, threads). */
	static function start(source:String, stdlib:Bool = false):{compiler:Compiler, build:Dynamic, live:runtime.LoadedModule, mainId:Int} {
		var compiler = new Compiler();
		if (stdlib) {
			CompilerIntrinsics.register(compiler);
			compiler.addSourceRoot("stdlib");
		}
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
