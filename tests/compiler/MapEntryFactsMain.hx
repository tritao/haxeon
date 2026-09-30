import compiler.Frontend;
import compiler.Diagnostic.CompileError;

/**
 * `exists` proves an entry is present until something can remove it. Calls can remove entries from any map they reach,
 * so only a local map that never leaves its function keeps that fact across them.
 */
class MapEntryFactsMain {
	static final prelude = "class Box { public var n = 0; public function new() {} public function bump():Void { n++; } } "
		+ "function drain(m:Map<String, Int>):Void { m.remove(\"a\"); } ";
	static final setup = "var m:Map<String, Int> = new Map(); m.set(\"a\", 42); var b = new Box(); var k = \"a\"; ";

	static function main():Void {
		expectCompiles("a private map keeps its entry across a call", "if (m.exists(k)) { b.bump(); return m.get(k); } return 0;");
		expectCompiles("and across several", "if (!m.exists(k)) return 0; b.bump(); b.bump(); return m.get(k);");
		expectCompiles("a key the map was given keeps it across a call", "m.set(\"b\", 42); b.bump(); return m.get(\"b\");");

		expectError("a map handed to a function may lose the entry", "if (m.exists(k)) { drain(m); return m.get(k); } return 0;");
		expectError("a map stored in an object may lose the entry",
			"var holder = {inner: m}; if (m.exists(k)) { b.bump(); return m.get(k); } return holder.inner.size();");
		expectCompiles("a lambda that only reads the map cannot remove entries",
			"var f = function():Int return m.size(); if (m.exists(k)) { b.bump(); return m.get(k) + f() - f(); } return 0;");
		expectError("a lambda that removes entries may lose the entry",
			"var f = function():Void { m.remove(\"a\"); }; if (m.exists(k)) { b.bump(); return m.get(k); } return 0;");
		expectError("a map parameter may be reachable from the caller", "return read(m); ",
			"function read(m:Map<String, Int>):Int { var b = new Box(); if (m.exists(\"a\")) { b.bump(); return m.get(\"a\"); } return 0; } ");
		expectError("a map that is reassigned is not known to be private",
			"var other:Map<String, Int> = new Map(); m = other; if (m.exists(k)) { b.bump(); return m.get(k); } return 0;");

		expectError("removing the entry forgets it", "if (m.exists(k)) { m.remove(k); return m.get(k); } return 0;");
		expectError("removing another spelling of the key forgets it", "var j = \"a\"; if (m.exists(k)) { m.remove(j); return m.get(k); } return 0;");
		expectError("clearing the map forgets it", "if (m.exists(k)) { m.clear(); return m.get(k); } return 0;");
		expectError("reassigning the key forgets it", "if (m.exists(k)) { k = \"b\"; return m.get(k); } return 0;");
		expectError("incrementing an Int key forgets it",
			"var n:Map<Int, Int> = new Map(); n.set(1, 42); var i = 1; if (n.exists(i)) { i++; return n.get(i); } return 0;");
		expectError("so does a postfix increment",
			"var n:Map<Int, Int> = new Map(); n.set(1, 42); var i = 1; if (n.exists(i)) { var old = i++; return n.get(i); } return 0;");
		Sys.println("PASS: map entry facts");
	}

	static function wrap(body:String, extra:String):String
		return prelude + extra + "function main():Int { " + setup + body + " }";

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
