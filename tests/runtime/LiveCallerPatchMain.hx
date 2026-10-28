import compiler.hl.HlWriter;
import compiler.Compiler;
import runtime.PatchSet;
import runtime.Runtime;

/**
 * A function whose signature changes takes a new slot. Every caller that called its old slot is compiled again in the same
 * patch, those in files the edit did not touch too, so no direct call keeps reaching the old code.
 */
class LiveCallerPatchMain {
	static final callee = [
		"function scale(v:Int):Int return v * 2;\n",
		"function scale(v:Int, by:Int = 3):Int return v * by;\n",
		"function scale(v:Int, by:Int = 3, plus:Int = 0):Int return v * by + plus + 1000;\n"
	];

	static function main():Void {
		var compiler = new Compiler();
		compiler.update("Other.hx", "class Other {\n  public static function twice(v:Int):Int return Main.scale(v) + Main.scale(v);\n}\n");
		compiler.update("Main.hx", source(0));
		var build = compiler.compile("Main"),
			live = Runtime.load(HlWriter.encode(build.module), build.runtimeIdentity),
			mainId = build.functionIds.get("main");
		// twice(5) = 10 + 10, scale(1) = 2.
		expect(Runtime.callInt(live, mainId), 20 * 1000 + 2, "before the edits");
		for (version in 1...callee.length) {
			compiler.update("Main.hx", source(version));
			var changed = compiler.compile("Main");
			if (changed.requiresReload || changed.patchBytes == null)
				throw 'version $version: required a reload: ${[for (reason in changed.reloadReasons) Std.string(reason)].join(", ")}';
			Runtime.patchSet(live, new PatchSet(build.revision, changed.revision, changed.patchBytes, changed.changedFunctions));
			build = changed;
			var expected = fresh(changed);
			expect(Runtime.callInt(live, mainId), expected, 'version $version, the patched module against a fresh one');
		}
		Runtime.dispose(live);
		Sys.println("PASS: callers of a function whose signature changed call its new code, from files the edit did not touch too");
	}

	static function source(version:Int):String
		return callee[version] + "function main():Int return Other.twice(5) * 1000 + scale(1);\n";

	static function fresh(build:Dynamic):Int {
		var module = Runtime.load(HlWriter.encode(build.module), build.runtimeIdentity);
		var value = Runtime.callInt(module, build.functionIds.get("main"));
		Runtime.dispose(module);
		return value;
	}

	static function expect(actual:Int, expected:Int, label:String):Void
		if (actual != expected)
			throw '$label: the program returned $actual instead of $expected';
}
