import compiler.Frontend;
import compiler.Diagnostic.CompileError;
import compiler.ir.IrInterpreter;

/** A loop condition proves facts about its variables for the body, until the body reassigns them. */
class LoopNarrowingMain {
	static final nodes = "typedef Node = {value:Int, next:Null<Node>}; ";
	static final chain = "var n:Null<Node> = {value: 40, next: {value: 2, next: null}}; var sum = 0; ";

	static function main():Void {
		expectValue("null test narrows the body and survives the reassignment that advances it",
			nodes
			+ "function main():Int { "
			+ chain
			+ "while (n != null) { sum += n.value; n = n.next; } return sum; }");
		expectValue("negated null test narrows the body",
			nodes
			+ "function main():Int { "
			+ chain
			+ "while (!(n == null)) { sum += n.value; n = n.next; } return sum; }");
		expectValue("conjunction narrows the body",
			nodes
			+ "function main():Int { "
			+ chain
			+ "var go = true; while (go && n != null) { sum += n.value; n = n.next; } return sum; }");
		expectValue("narrowing does not leak after the loop",
			nodes
			+ "function main():Int { "
			+ chain
			+ "while (n != null) { sum += n.value; n = n.next; } return n == null ? sum : 0; }");
		expectCompileError("a reassignment forgets the narrowing",
			nodes
			+ "function main():Int { "
			+ chain
			+ "while (n != null) { n = n.next; sum += n.value; } return sum; }");
		expectCompileError("no narrowing without a test", nodes
			+ "function main():Int { "
			+ chain
			+ "while (sum < 1) { sum += n.value; } return sum; }");
		// The loop ends when the condition is false, so what a false condition proves holds after it.
		var wait = "var x:Null<Int> = null; var i = 0; ";
		expectValue("a loop that waits for a value leaves it non-null",
			"function main():Int { " + wait + "while (x == null) { i++; if (i > 2) x = 42; } var z:Int = x; return z; }");
		expectValue("a do-while does too", "function main():Int { " + wait + "do { i++; if (i > 2) x = 42; } while (x == null); var z:Int = x; return z; }");
		expectValue("a break in a nested loop is that loop's",
			"function main():Int { " + wait + "while (x == null) { for (j in 0...2) { if (j == 1) break; } x = 42; } var z:Int = x; return z; }");
		expectCompileError("a break can leave with the condition still true",
			"function main():Int { " + wait + "while (x == null) { i++; if (i > 2) break; } var z:Int = x; return z; }");
		expectCompileError("a compound condition proves nothing when false",
			"function main():Int { " + wait + "while (x == null && i < 5) { i++; } var z:Int = x; return z; }");
		Sys.println("PASS: loop conditions narrow the loop body");
	}

	static function expectValue(label:String, source:String):Void {
		var value = new IrInterpreter(Frontend.compile(source)).run("main");
		if (value != 42)
			throw '$label returned $value instead of 42';
	}

	static function expectCompileError(label:String, source:String):Void {
		try {
			Frontend.compile(source);
		} catch (error:CompileError) {
			return;
		}
		throw '$label unexpectedly compiled';
	}
}
