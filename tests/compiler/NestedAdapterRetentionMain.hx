import compiler.Compiler;

/** A retained generic lambda can own an adapter, which owns its capture environment. */
class NestedAdapterRetentionMain {
	static function main():Void {
		var compiler = new Compiler();
		compiler.update("Util.hx",
			"function wrap<T>(value:T):Int { var f = function(x:Int):Int return x+1; var nested = function():Int { var d:Dynamic->Dynamic = f; return d(41); }; return nested(); }");
		compiler.update("Other.hx", "function other():Int return 0;");
		compiler.update("Main.hx", "function main():Int return Util.wrap(5) + Other.other();");
		compiler.compile("Main");
		compiler.update("Other.hx", "function other():Int return 1;");
		var retained = compiler.compile("Main");
		var adapters = [
			for (fn in retained.ir.functions)
				if (StringTools.startsWith(fn.name, "$function-adapter:$lambda:$generic:")) fn.name
		];
		if (adapters.length == 0)
			throw "Nested adapter was not retained";
		// Remove the caller: the specialization and its descendants must be pruned too.
		compiler.update("Main.hx", "function main():Int return Other.other();");
		var removed = compiler.compile("Main");
		for (fn in removed.ir.functions)
			if (adapters.indexOf(fn.name) >= 0)
				throw "Orphaned adapter survived removed caller";
		Sys.println("PASS: retained generic lambdas retain nested adapters and prune them with their caller");
	}
}
