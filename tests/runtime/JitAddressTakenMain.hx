/**
 * Stock Haxe's EReg.split keeps its running offsets in locals whose address is passed to the matcher. The JIT must not
 * replace a read of such a local by the constant it started as, even when that constant is an operand of an addition.
 * Compiled by Haxe, not by Haxeon, so it runs the standard library's own bytecode.
 */
class JitAddressTakenMain {
	static function fail(code:Int, message:String):Void {
		Sys.println("FAIL: " + message);
		Sys.exit(code);
	}

	static function main():Void {
		var parts = new EReg(",\\s*", "g").split("a, b,c,   d");
		if (parts.join("|") != "a|b|c|d")
			fail(1, "comma split gave " + parts.join("|"));
		var pieces = new EReg("x", "g").split("axbxxc");
		if (pieces.join("|") != "a|b||c")
			fail(2, "x split gave " + pieces.join("|"));
		var edges = new EReg("/", "g").split("/a//b/");
		if (edges.join("|") != "|a||b|" || edges.length != 5)
			fail(3, "slash split gave " + edges.join("|"));
		var total = 0;
		for (round in 0...300)
			total += new EReg("[,;]", "g").split("a,b;c,d;e,f").length;
		if (total != 300 * 6)
			fail(4, "repeated split totalled " + total);
		Sys.println("PASS: EReg.split keeps its offsets in address-taken locals");
	}
}
