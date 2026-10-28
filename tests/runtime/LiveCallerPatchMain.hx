import compiler.hl.HlWriter;
import compiler.Compiler;
import runtime.PatchSet;
import runtime.Runtime;
import compiler.abi.PatchPlanner.PatchDecision;
import compiler.hl.HlFunction;

/**
 * A function whose signature changes takes a new slot. Every caller that called its old slot is compiled again in the same
 * patch, those in files the edit did not touch too, so no direct call keeps reaching the old code.
 */
class LiveCallerPatchMain {
	// Recursive, so the inliner leaves the calls to it in place.
	static final callee = [
		"function scale(v:Int):Int return v <= 0 ? 0 : 2 + scale(v - 1);\n",
		"function scale(v:Int, by:Int = 3):Int return v <= 0 ? 0 : by + scale(v - 1, by);\n",
		"function scale(v:Int, by:Int = 3, plus:Int = 0):Int return v <= 0 ? plus + 1000 : by + scale(v - 1, by, plus);\n"
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
		assemblerRecompilesCallers();
		Sys.println("PASS: callers of a function whose signature changed call its new code, from files the edit did not touch too");
	}

	/**
	 * The assembler on its own: told that only `scale` changed, it still lowers `Other.twice` again, because its lowered code
	 * calls the slot `scale` left.
	 */
	static function assemblerRecompilesCallers():Void {
		var first = new Compiler(), second = new Compiler();
		for (compiler in [first, second])
			compiler.update("Other.hx", "class Other {\n  public static function twice(v:Int):Int return Main.scale(v) + Main.scale(v);\n}\n");
		first.update("Main.hx", source(0));
		second.update("Main.hx", source(1));
		var before = first.compile("Main").ir, after = second.compile("Main").ir;
		var assembler = new compiler.hl.incremental.HlModuleAssembler();
		assembler.fieldReserve = 0;
		assembler.assemble(before, [for (fn in before.functions) fn.name], Patch);
		var assembly = assembler.assemble(after, ["Main.scale"], Patch);
		if (assembly.requiresReload)
			throw 'the assembler reloaded: ${assembly.layoutReasons.join(", ")}';
		var twiceId = assembler.cache.stableIds.get("Other.twice"), scaleSlot = assembly.functionIndices.get("Main.scale");
		if (assembly.changedFunctions.indexOf(twiceId) < 0)
			throw 'Other.twice calls the slot Main.scale left, but the patch does not compile it again';
		var twiceSlot = assembly.functionIndices.get("Other.twice"), calls = 0;
		for (fn in assembly.module.functions)
			if (fn.functionIndex == twiceSlot)
				for (opcode in fn.opcodes)
					switch opcode {
						case Call0(_, target) | Call1(_, target, _) | Call2(_, target, _, _) | CallN(_, target, _):
							if (target != scaleSlot)
								throw 'Other.twice calls slot $target, not the new slot $scaleSlot of Main.scale';
							calls++;
						default:
					}
		if (calls != 2)
			throw 'Other.twice makes $calls calls to Main.scale, not 2';
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
