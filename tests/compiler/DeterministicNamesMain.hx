import compiler.Compiler;

/**
 * What a build produces must depend on the source, not on which build made it.
 *
 * - A function adapter was numbered by a counter shared by the whole typing run, so retyping one function alone gave it a
 *   different name from the one it got when everything was typed together.
 * - A lambda inside a generic specialization is named by its source offset. After an edit moved it, the old lambda was still
 *   kept as if it were a specialization whose origin had not changed, so the incremental build carried both.
 * - The environment object of a lambda or adapter stayed in the object cache after its function was renamed or removed.
 */
class DeterministicNamesMain {
	static final a = "function first():Int { var g = function(x:Int):Int { return x + 1; }; var d:(Dynamic)->Dynamic = g; return d(1); }";
	static final b1 = "function second():Int { var g = function(x:Int):Int { return x + 2; }; var d:(Dynamic)->Dynamic = g; return d(1); }";
	static final b2 = "function second():Int { var g = function(x:Int):Int { return x + 3; }; var d:(Dynamic)->Dynamic = g; return d(1); }";
	static final util1 = "function wrap<T>(value:T):Int { var f = function():Int { return 1; }; return f(); }";
	static final util2 = "function wrap<T>(value:T):Int { var padding = 12345; var f = function():Int { return 1; }; return f() + padding - padding; }";
	static final mainSource = "function main():Int { return A.first() + B.second() + Util.wrap(5) + Util.wrap(\"s\"); }";

	static function generatedNames(compiler:Compiler):Array<String> {
		var result = compiler.compile("Main", null, false);
		var names = [
			for (fn in result.ir.functions)
				if (fn.name.indexOf("adapter") >= 0 || fn.name.indexOf("$lambda") >= 0 || fn.name.indexOf("$generic") >= 0) fn.name
		];
		for (object in result.ir.objects)
			if (object.name.indexOf("-env:") >= 0)
				names.push("object " + object.name);
		names.sort(Reflect.compare);
		return names;
	}

	static function main():Void {
		var incremental = new Compiler();
		incremental.update("A.hx", a);
		incremental.update("B.hx", b1);
		incremental.update("Util.hx", util1);
		incremental.update("Main.hx", mainSource);
		generatedNames(incremental);
		incremental.update("B.hx", b2);
		incremental.update("Util.hx", util2);
		var afterEdit = generatedNames(incremental);

		var cold = new Compiler();
		cold.update("A.hx", a);
		cold.update("B.hx", b2);
		cold.update("Util.hx", util2);
		cold.update("Main.hx", mainSource);
		var fresh = generatedNames(cold);

		if (afterEdit.length == 0 || afterEdit.join(",") != fresh.join(","))
			throw 'Generated names differ between an incremental and a cold build:\n  incremental: $afterEdit\n  cold:        $fresh';
		Sys.println("PASS: incremental and cold builds generate the same functions with the same names");
	}
}
