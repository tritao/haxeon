import compiler.Frontend;
import compiler.Diagnostic.CompileError;

/**
 * A loop body runs again after itself, so a fact proved before the loop only holds inside it, and after it, when
 * nothing in the body can undo it.
 */
class LoopFlowMain {
	static final prelude = "class Holder { public var value:Null<Int> = 5; public function new() {} } function reset(h:Holder):Void { h.value = null; } function drop(h:Holder):Int { h.value = null; return 1; } ";

	static function main():Void {
		expectCompiles("a read-only loop keeps a field fact",
			"var h = new Holder(); var total = 0; if (h.value != null) { for (i in 0...3) { total += h.value; } var z:Int = h.value; return z + total; } return 0;");
		expectCompiles("assigning an unrelated local keeps it too",
			"var h = new Holder(); var i = 0; if (h.value != null) { while (i < 2) { var z:Int = h.value; i++; } } return 0;");
		expectError("an impure call later in the body clears the fact for the next iteration",
			"var h = new Holder(); var i = 0; if (h.value != null) { while (i < 2) { var z:Int = h.value; reset(h); i++; } } return 0;");
		expectError("and after the loop",
			"var h = new Holder(); var i = 0; if (h.value != null) { while (i < 2) { reset(h); i++; } var z:Int = h.value; } return 0;");
		expectError("in a for loop", "var h = new Holder(); if (h.value != null) { for (i in 0...2) { var z:Int = h.value; reset(h); } } return 0;");
		expectError("in a do-while loop",
			"var h = new Holder(); var i = 0; if (h.value != null) { do { var z:Int = h.value; reset(h); i++; } while (i < 2); } return 0;");
		expectError("in a comprehension", "var h = new Holder(); if (h.value != null) { var xs = [for (i in 0...2) h.value + drop(h)]; } return 0;");

		expectError("a local narrowed before the loop and cleared in it",
			"var x:Null<Int> = 1; var i = 0; if (x != null) { while (i < 2) { var z:Int = x; x = null; i++; } } return 0;");
		expectError("a local cleared in the loop is not narrowed after it",
			"var x:Null<Int> = 1; var i = 0; if (x != null) { while (i < 2) { x = null; i++; } var z:Int = x; } return 0;");
		expectCompiles("a local only read in the loop stays narrowed",
			"var x:Null<Int> = 1; var i = 0; if (x != null) { while (i < 2) { var z:Int = x; i++; } var w:Int = x; } return 0;");

		expectCompiles("keys of a private map keep their entries across calls",
			"var m:Map<String, Int> = new Map(); m.set(\"a\", 1); var h = new Holder(); for (k in m.keys()) { reset(h); var v:Int = m.get(k); } return 0;");
		expectCompiles("removing only the visited key leaves the rest",
			"var m:Map<String, Int> = new Map(); m.set(\"a\", 1); for (k in m.keys()) { var v:Int = m.get(k); m.remove(k); } return 0;");
		expectError("removing another key may take out one still to be visited",
			"var m:Map<String, Int> = new Map(); m.set(\"a\", 1); for (k in m.keys()) { m.remove(\"b\"); var v:Int = m.get(k); } return 0;");
		expectError("clearing the map may too",
			"var m:Map<String, Int> = new Map(); m.set(\"a\", 1); for (k in m.keys()) { m.clear(); var v:Int = m.get(k); } return 0;");
		expectError("an entry proved before a loop that removes it",
			"var m:Map<String, Int> = new Map(); m.set(\"a\", 1); var i = 0; if (m.exists(\"a\")) { while (i < 2) { var v:Int = m.get(\"a\"); m.remove(\"a\"); i++; } } return 0;");
		Sys.println("PASS: loops and flow facts");
	}

	static function wrap(body:String):String
		return prelude + "function main():Int { " + body + " }";

	static function expectCompiles(label:String, body:String):Void {
		try {
			Frontend.compile(wrap(body));
		} catch (error:CompileError) {
			throw '$label failed to compile: ${error.diagnostic.format()}';
		}
	}

	static function expectError(label:String, body:String):Void {
		try {
			Frontend.compile(wrap(body));
		} catch (error:CompileError) {
			return;
		}
		throw '$label unexpectedly compiled';
	}
}
