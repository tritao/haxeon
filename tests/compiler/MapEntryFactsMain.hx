import compiler.Frontend;
import compiler.core.Diagnostic.CompileError;

/**
 * `exists` proves an entry is present until something can remove it. Calls can remove entries from any map they reach,
 * so only a local map that never leaves its function keeps that fact across them.
 */
class MapEntryFactsMain {
	// Entries are references, so reading `.n` needs the entry fact. (A missing Int entry would read as 0, as in Haxe.)
	static final prelude =
		"class Entry { public final n:Int; public function new(n:Int) this.n = n; } class Box { public var n = 0; public function new() {} public function bump():Void { n++; } } "
		+ "function drain(m:Map<String, Entry>):Void { m.remove(\"a\"); } ";
	static final setup =
		"var m:Map<String, Entry> = new Map(); m.set(\"a\", new Entry(42)); var b = new Box(); var k = \"a\"; ";

	static function main():Void {
		expectCompiles("a private map keeps its entry across a call",
			"if (m.exists(k)) { b.bump(); return m.get(k).n; } return 0;");
		expectCompiles("and across several", "if (!m.exists(k)) return 0; b.bump(); b.bump(); return m.get(k).n;");
		expectCompiles("a key the map was given keeps it across a call",
			"m.set(\"b\", new Entry(42)); b.bump(); return m.get(\"b\").n;");

		// Declarations are told apart by scope, not by name.
		expectCompiles("sibling blocks may each declare a private map of the same name",
			"var flag = true; if (flag) { var parts:Map<String, Entry> = new Map(); parts.set(\"a\", new Entry(42)); if (parts.exists(k)) { b.bump(); return parts.get(k).n; } } "
			+ "else { var parts:Map<String, Entry> = new Map(); parts.set(\"a\", new Entry(42)); if (parts.exists(k)) { b.bump(); return parts.get(k).n; } } return 0;");
		expectCompiles("a loop variable of the same name is another variable",
			"var total = 0; for (m in [1, 2]) { total += m; } if (m.exists(k)) { b.bump(); return m.get(k).n; } return total;");
		expectCompiles("so is a lambda parameter",
			"var f = function(m:Int):Int return m + 1; if (m.exists(k)) { b.bump(); return m.get(k).n + f(0) - 1; } return 0;");
		expectCompiles("so is a catch variable",
			"try { b.bump(); } catch (m:Dynamic) { b.bump(); } if (m.exists(k)) { b.bump(); return m.get(k).n; } return 0;");
		expectError("an inner private map does not make an escaping outer one safe",
			"{ var m:Map<String, Entry> = new Map(); m.set(\"z\", new Entry(1)); } drain(m); if (m.exists(k)) { b.bump(); return m.get(k).n; } return 0;");
		expectError("a map handed to a function may lose the entry",
			"if (m.exists(k)) { drain(m); return m.get(k).n; } return 0;");
		expectError("a map stored in an object may lose the entry",
			"var holder = {inner: m}; if (m.exists(k)) { b.bump(); return m.get(k).n; } return holder.inner.size();");
		expectCompiles("a lambda that only reads the map cannot remove entries",
			"var f = function():Int return m.size(); if (m.exists(k)) { b.bump(); return m.get(k).n + f() - f(); } return 0;");
		expectError("a lambda that removes entries may lose the entry",
			"var f = function():Void { m.remove(\"a\"); }; if (m.exists(k)) { b.bump(); return m.get(k).n; } return 0;");
		expectError("a map parameter may be reachable from the caller", "return read(m); ",
			"function read(m:Map<String, Entry>):Int { var b = new Box(); if (m.exists(\"a\")) { b.bump(); return m.get(\"a\").n; } return 0; } ");
		expectError("a map that is reassigned is not known to be private",
			"var other:Map<String, Entry> = new Map(); m = other; if (m.exists(k)) { b.bump(); return m.get(k).n; } return 0;");

		expectError("removing the entry forgets it", "if (m.exists(k)) { m.remove(k); return m.get(k).n; } return 0;");
		expectError("removing another spelling of the key forgets it",
			"var j = \"a\"; if (m.exists(k)) { m.remove(j); return m.get(k).n; } return 0;");
		expectError("clearing the map forgets it", "if (m.exists(k)) { m.clear(); return m.get(k).n; } return 0;");
		expectError("reassigning the key forgets it", "if (m.exists(k)) { k = \"b\"; return m.get(k).n; } return 0;");
		expectError("incrementing an Int key forgets it",
			"var n:Map<Int, Entry> = new Map(); n.set(1, new Entry(42)); var i = 1; if (n.exists(i)) { i++; return n.get(i).n; } return 0;");
		expectError("so does a postfix increment",
			"var n:Map<Int, Entry> = new Map(); n.set(1, new Entry(42)); var i = 1; if (n.exists(i)) { var old = i++; return n.get(i).n; } return 0;");
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
