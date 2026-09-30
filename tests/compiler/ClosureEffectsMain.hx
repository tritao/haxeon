import compiler.Frontend;
import compiler.Diagnostic.CompileError;

/**
 * A call through a function value can run anything, so it clears what flow analysis knows about mutable state. A call
 * through a local function runs a known body, so it clears that only when the body could change it.
 */
class ClosureEffectsMain {
	static final prelude = "class Holder { public var value:Null<Int> = 5; public function new() {} } ";

	static function main():Void {
		expectCompiles("a local function without effects keeps a field fact",
			"var h = new Holder(); var twice = function(x:Int):Int return x * 2; if (h.value != null) { var y = twice(1); var z:Int = h.value; return z + y; } return 0;");
		expectCompiles("so does a named local function",
			"var h = new Holder(); function twice(x:Int):Int return x * 2; if (h.value != null) { var y = twice(1); var z:Int = h.value; return z + y; } return 0;");
		expectCompiles("a local function that only reads keeps the fact",
			"var h = new Holder(); var peek = function():Int return h.value == null ? 0 : 1; if (h.value != null) { var y = peek(); var z:Int = h.value; return z + y; } return 0;");

		expectError("a local function that writes the field clears the fact",
			"var h = new Holder(); var poke = function():Void { h.value = null; }; if (h.value != null) { poke(); var z:Int = h.value; return z; } return 0;");
		expectError("a local function that removes a map entry clears the fact",
			"var m:Map<String, Int> = new Map(); m.set(\"a\", 1); var drop = function():Void { m.remove(\"a\"); }; if (m.exists(\"a\")) { drop(); return m.get(\"a\"); } return 0;");
		expectError("a local function that calls an impure function clears the fact",
			"var h = new Holder(); var poke = function():Void { reset(h); }; if (h.value != null) { poke(); var z:Int = h.value; return z; } return 0;",
			"function reset(h:Holder):Void { h.value = null; } ");
		expectError("a function value that is not a known local clears the fact", "return run(function():Void {}, new Holder()); ",
			"function run(callback:() -> Void, h:Holder):Int { if (h.value != null) { callback(); var z:Int = h.value; return z; } return 0; } ");
		expectError("a reassigned local function is not a known body",
			"var h = new Holder(); var f = function():Void {}; f = function():Void { h.value = null; }; if (h.value != null) { f(); var z:Int = h.value; return z; } return 0;");
		Sys.println("PASS: closure calls and flow facts");
	}

	static function wrap(body:String, extra:String):String
		return prelude + extra + "function main():Int { " + body + " }";

	static function expectCompiles(label:String, body:String):Void {
		try {
			Frontend.compile(wrap(body, ""));
		} catch (error:CompileError) {
			throw '$label failed to compile: ${error.diagnostic.message}';
		}
	}

	static function expectError(label:String, body:String, ?extra:String):Void {
		try {
			Frontend.compile(wrap(body, extra == null ? "" : extra));
		} catch (error:CompileError) {
			return;
		}
		throw '$label unexpectedly compiled';
	}
}
