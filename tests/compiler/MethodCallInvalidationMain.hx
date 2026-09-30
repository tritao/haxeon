import compiler.Compiler;

/**
 * In a command-line build (no semantic index), a caller of an instance method is regenerated when that method's
 * signature changes, however the receiver is held: a local, a field, a parameter, a local inside a lambda. Before
 * typing, `gate.worst()` only names the local `gate`, so the dependency on `Gate.worst` has to come from what
 * typing resolved the call to; otherwise the caller keeps the code it was lowered to for the old signature, and
 * the build fails IR verification when the method merely gains an optional parameter.
 */
class MethodCallInvalidationMain {
	static function check(label:String, main:String, callerName:String):Void {
		var compiler = new Compiler();
		compiler.update("Gate.hx", "class Gate { public function new() {} public function worst():Float return 1.0; }");
		compiler.update("Main.hx", main);
		compiler.compile("Main", null, false);
		// The method gains an optional parameter: every caller still type-checks, but must be lowered again.
		compiler.update("Gate.hx", "class Gate { public function new() {} public function worst(scale:Float = 1.0):Float return 1.0 * scale; }");
		var changed = compiler.compile("Main", null, false);
		if (changed.regenerated.indexOf(callerName) >= 0)
			return;
		throw '$label: $callerName was not regenerated when Gate.worst gained a parameter: ${changed.regenerated}';
	}

	static function main():Void {
		check("local", "class Main { static function main():Int { var gate = new Gate(); return gate.worst() > 0.5 ? 0 : 1; } }", "Main.main");
		check("field", "class Main { static final gate = new Gate(); static function main():Int return gate.worst() > 0.5 ? 0 : 1; }", "Main.main");
		check("parameter",
			"class Main { static function main():Int return use(new Gate()); static function use(gate:Gate):Int return gate.worst() > 0.5 ? 0 : 1; }",
			"Main.use");
		check("lambda",
			"class Main { static function main():Int { var gate = new Gate(); var probe = function() return gate.worst() > 0.5 ? 0 : 1; return probe(); } }",
			"Main.main");
		Sys.println("PASS: a change to an instance method's signature regenerates its callers through any receiver");
	}
}
