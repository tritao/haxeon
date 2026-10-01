import compiler.Compiler;

/**
 * Without a semantic index to rebuild (command-line builds), editing one module must not retype or regenerate the
 * functions of a module whose source did not change, even though one of them calls into the edited module.
 */
class IncrementalSnapshotMain {
	static function main():Void {
		var compiler = new Compiler();
		compiler.update("Util.hx", "function one():Int { return 1; } function two():Int { return one() + 1; } function unused():Int { return 9; }");
		compiler.update("Main.hx",
			"function helper():Int { return 5; } function other():Int { return helper() + 1; } " + "function main():Int { return Util.two() + other(); }");
		compiler.compile("Main", null, false);

		// Util.two gains an optional parameter, so its caller Main.main is invalidated and Main's module snapshot would be
		// refreshed. Main.helper and Main.other did not change and must be left alone.
		compiler.update("Util.hx",
			"function one():Int { return 10; } function two(extra:Int = 0):Int { return one() + 1 + extra; } function unused():Int { return 9; }");
		var changed = compiler.compile("Main", null, false);
		var regenerated = changed.regenerated;
		if (regenerated.indexOf("Util.two") < 0 || regenerated.indexOf("main") < 0)
			throw 'The edited function or its caller was not regenerated: $regenerated';
		for (untouched in ["Main.helper", "Main.other"])
			if (regenerated.indexOf(untouched) >= 0)
				throw '$untouched is in a module whose source did not change and was regenerated: $regenerated';

		// The same edit with an index to maintain refreshes the whole module snapshot, as before.
		var indexed = new Compiler();
		indexed.update("Util.hx", "function one():Int { return 1; } function two():Int { return one() + 1; } function unused():Int { return 9; }");
		indexed.update("Main.hx",
			"function helper():Int { return 5; } function other():Int { return helper() + 1; } " + "function main():Int { return Util.two() + other(); }");
		indexed.compile("Main");
		indexed.update("Util.hx",
			"function one():Int { return 10; } function two(extra:Int = 0):Int { return one() + 1 + extra; } function unused():Int { return 9; }");
		var indexedResult = indexed.compile("Main");
		if (indexedResult.regenerated.indexOf("Main.helper") < 0)
			throw 'An indexed compile should refresh the whole snapshot of a module with an invalid function: ${indexedResult.regenerated}';
		Sys.println("PASS: unindexed incremental builds skip snapshot refreshes of unchanged modules");
	}
}
