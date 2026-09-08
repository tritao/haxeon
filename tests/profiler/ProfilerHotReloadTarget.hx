import compiler.Compiler;
import compiler.hl.HlWriter;
import runtime.PatchSet;
import runtime.Runtime;

class ProfilerHotReloadTarget {
	static function main():Void {
		var args = Sys.args(),
			beforePatch = args.length > 0 ? Std.parseFloat(args[0]) : 5.0,
			afterPatch = args.length > 1 ? Std.parseFloat(args[1]) : 3.0;
		var compiler = new Compiler();
		compiler.update("Work.hx",
			"function work():Int { var result = 42; if (true) { var scoped = result + 100; result = scoped - 99; scoped = scoped + 0; } result = result - 1; try { throw \"profile\"; } catch (error:Int) { result = 0; } catch (error:String) { result = result + 0; } return result; }");
		compiler.update("Main.hx", "function main():Int return Work.work();");
		var initial = compiler.compile("Main"),
			workId = initial.functionIds.get("Work.work"),
			loaded = Runtime.load(HlWriter.encode(initial.module), initial.runtimeIdentity);
		Sys.sleep(2.0);
		runFor(loaded, workId, beforePatch);
		compiler.update("Work.hx",
			"function work():Int { var result = 43; if (true) { var scoped = result + 100; result = scoped - 99; scoped = scoped + 0; } result = result - 1; try { throw \"profile\"; } catch (error:Int) { result = 0; } catch (error:String) { result = result + 0; } return result; }");
		var changed = compiler.compile("Main");
		Runtime.patchSet(loaded, new PatchSet(initial.revision, changed.revision, changed.patchBytes, changed.changedFunctions));
		Sys.println("PATCHED");
		runFor(loaded, workId, afterPatch);
		Runtime.dispose(loaded);
	}

	static function runFor(loaded:runtime.LoadedModule, workId:Int, seconds:Float):Void {
		var until = Sys.time() + seconds, value = 0;
		while (Sys.time() < until)
			value ^= Runtime.callInt(loaded, workId);
		if (value == -1)
			Sys.println(value);
	}
}
