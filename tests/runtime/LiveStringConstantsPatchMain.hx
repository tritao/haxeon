import compiler.abi.PatchPlanner.AbiChange;
import compiler.hl.patch.HlPatchReader;
import compiler.hl.HlWriter;
import compiler.types.Type.CompilerType;
import compiler.Compiler;
import runtime.PatchSet;
import runtime.Runtime;

/**
 * A literal in a live module is a global holding one String, as in any other build, so evaluating it allocates nothing.
 * A patch that introduces a literal adds that global; the patched code reads it with no allocation either, later patches
 * build on it, and the full module of the same build, which a rejected patch falls back to, runs identically.
 */
class LiveStringConstantsPatchMain {
	// 1000 evaluations of two literals per call. The module reports -1 if the loop allocated, and otherwise its own total.
	static function program(extra:String, call:String):String
		return "class Probe {\n" + "  public static function run(phase:String):Int {\n" + "    var total = 0;\n" + "    var before = allocated();\n"
			+ "    for (i in 0...1000) {\n" + "      if (phase == \"target\") total++;\n" + "      if (phase != \"bubble\") total++;\n" + extra + "    }\n"
			+ "    var used = allocated() - before;\n" + "    return used < 1000.0 ? total : -1;\n" + "  }\n" + "}\n" + "function main():Int {\n"
			+ "  return Probe.run(\"" + call + "\");\n" + "}\n";

	static function newCompiler():Compiler {
		var compiler = new Compiler();
		compiler.livePatching = true;
		compiler.registerNative("allocated", "std", "gc_total_allocated", [], CompilerType.TFloat);
		return compiler;
	}

	static function main():Void {
		var compiler = newCompiler();
		compiler.update("Main.hx", program("", "target"));
		var build = compiler.compile("Main");
		if (build.module.constants.length < 2)
			throw 'A live module should hold its literals as constants, got ${build.module.constants.length}';
		var live = Runtime.load(HlWriter.encode(build.module), build.runtimeIdentity),
			mainId = build.functionIds.get("main");
		expect(Runtime.callInt(live, mainId) == 2000, "The live module allocated while evaluating its literals, or computed the wrong total");
		var edits = [
			{
				label: "a new literal read in the loop",
				source: program("      if (phase == \"fresh\") total += 5;\n", "fresh"),
				expected: 6000,
				newGlobals: 1
			},
			{
				label: "a second new literal, on top of the first patch",
				source: program("      if (phase == \"fresh\") total += 5;\n      if (phase == \"second\") total += 7;\n", "second"),
				expected: 8000,
				newGlobals: 1
			},
			{
				label: "an edit that reuses both new literals",
				source: program("      if (phase == \"fresh\") total += 5;\n      if (phase == \"second\") total += 9;\n", "second"),
				expected: 10000,
				newGlobals: 0
			}
		];
		var globalsBefore = build.module.globals.length;
		for (edit in edits) {
			compiler.update("Main.hx", edit.source);
			var changed = compiler.compile("Main");
			if (changed.requiresReload || changed.patchBytes == null)
				throw '${edit.label} required a reload: ${[for (reason in changed.reloadReasons) Std.string(reason)].join(", ")}';
			for (reason in changed.reloadReasons)
				switch reason {
					case GlobalLayoutChanged(name):
						throw '${edit.label} changed the layout of global $name';
					default:
				}
			var decoded = HlPatchReader.decode(changed.patchBytes);
			expect(decoded.globals.length == edit.newGlobals
				&& decoded.baseGlobals == (edit.newGlobals == 0 ? 0 : build.module.globals.length),
				'${edit.label} should carry ${edit.newGlobals} new globals after ${build.module.globals.length}, got ${decoded.globals.length} after ${decoded.baseGlobals}');
			Runtime.patchSet(live, new PatchSet(build.revision, changed.revision, changed.patchBytes, changed.changedFunctions));
			var result = Runtime.callInt(live, mainId);
			expect(result == edit.expected, 'After ${edit.label} the patched module returned $result instead of ${edit.expected}');
			// A rejected patch falls back to loading the same build's full module, which must run on its own.
			var fresh = Runtime.load(HlWriter.encode(changed.module), changed.runtimeIdentity),
				reloaded = Runtime.callInt(fresh, changed.functionIds.get("main"));
			Runtime.dispose(fresh);
			expect(reloaded == edit.expected, 'After ${edit.label} the full module returned $reloaded instead of ${edit.expected}');
			build = changed;
		}
		expect(build.module.globals.length == globalsBefore + 2, 'Two new literals should add two globals, not ${build.module.globals.length - globalsBefore}');

		// A new mutable global is not a constant: that still takes a reload.
		compiler.update("Main.hx",
			program("      if (phase == \"second\") total += 9;\n",
				"second").split("class Probe {\n").join("class Probe {\n  public static var counter = 0;\n"));
		var layout = compiler.compile("Main");
		expect(layout.requiresReload && layout.patchBytes == null, "A new static variable must still require a reload");
		var layoutChanged = false;
		for (reason in layout.reloadReasons)
			switch reason {
				case GlobalLayoutChanged(_):
					layoutChanged = true;
				default:
			}
		expect(layoutChanged, "A new static variable should be reported as a global layout change");
		Runtime.dispose(live);
		Sys.println("PASS: literals in live modules are constants, and patches add the ones they introduce");
	}

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}
}
