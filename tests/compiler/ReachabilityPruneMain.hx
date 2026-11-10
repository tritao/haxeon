import compiler.Compiler;
import compiler.runtime.CompilerIntrinsics;

/**
 * HashLink drops what nothing reaches. A function nothing calls leaves the module; a class no reachable function mentions loses its
 * methods; a class that is mentioned keeps all of them, so a method that is only ever called by name still works.
 */
class ReachabilityPruneMain {
	static final source = "class Live { public function new() {} public function hidden():Int return 42; public function spare():Int return 7; } "
		+ "class Dead { public function new() {} public function never():Int return 1; } "
		+ "function unusedFree():Int return 5; "
		+ "function main():Int { var live = new Live(); var f:Dynamic = Reflect.field(live, \"hidden\"); return f == null ? 1 : f(); }";

	static function main():Void {
		var compiler = new Compiler();
		// A plain build prunes; a live one (the default of a `Compiler`) keeps every function.
		compiler.livePatching = false;
		CompilerIntrinsics.register(compiler);
		compiler.addStandardLibrarySourceRoot("stdlib");
		compiler.update("Main.hx", source);
		var result = compiler.compile("Main", null, false);
		// The passes already see only what is reachable, so the program in the result is pruned too.
		var irNames:Map<String, Bool> = [for (fn in result.ir.functions) fn.name => true];
		expect(!irNames.exists("Main.unusedFree") && !irNames.exists("Dead.never"), "the program the passes produce has no unreachable function");
		var names = result.functionIndices;
		expect(names.exists("main"), "main stays");
		expect(!names.exists("Main.unusedFree") && !names.exists("unusedFree"), "a function nothing calls is not in the module");
		expect(!names.exists("Dead.never") && !names.exists("Dead.new"), "the methods of a class nothing mentions are not in the module");
		expect(names.exists("Live.hidden"), "a mentioned class keeps its methods");
		expect(names.exists("Live.spare"), "a mentioned class keeps the methods nothing calls too: they can be reached by name");
		expect(GeneratedProgramRunner.exitCode(result) == 42, "a method reached only by name through Reflect.field runs");
		Sys.println("PASS: unreachable functions and the methods of unmentioned classes are dropped, reflection on a live class still works");
	}

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}
}
