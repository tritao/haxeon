import compiler.Compiler;
import compiler.hl.HlWriter;
import runtime.Runtime;

/** Exercises string map value iteration and a nested capture that depends on it. */
class MapValuesMain {
	static function main():Void {
		var compiler = new Compiler();
		compiler.update("Main.hx",
			'class Main { static function main():Int { '
			+ 'var bindings:Map<String, String> = []; bindings.set("selectedIndex", "selectedIndex@114"); '
			+ 'var found = false; for (binding in bindings) if (binding == "selectedIndex@114") found = true; '
			+ 'if (!found) return 1; '
			+ 'var numeric:Map<Int, String> = []; numeric.set(7, "seven"); '
			+ 'var numericValue = ""; for (item in numeric) numericValue = item; if (numericValue != "seven") return 3; '
			+ 'var options = ["One", "Two"]; '
			+ 'var choose = function() { var selectedIndex = -1; if (selectedIndex < 0) selectedIndex = 0; '
			+ 'var action = function() return options[selectedIndex]; return action(); }; '
			+ 'return choose() == "One" ? 0 : 2; } }');
		var result = compiler.compile("Main");
		var live = Runtime.load(HlWriter.encode(result.module), result.runtimeIdentity);
		var code = Runtime.callInt(live, result.functionIds.get("Main.main"));
		Runtime.dispose(live);
		if (code != 0)
			throw 'Map value iteration or nested capture failed: $code';
		Sys.println("PASS: map value iteration and nested capture");
	}
}
