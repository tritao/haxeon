import compiler.Frontend;
import compiler.Diagnostic.CompileError;

class FinalLocalMain {
	static function main():Void {
		for (body in [
			"final a = 1, b:Int = a + 1; return b;",
			"final a = 1; if (true) { var a = 2; a++; } return a;",
			"final a = [1]; a[0] = 2; return a[0];"
		])
			Frontend.compile("function main():Int { " + body + " }");
		for (body in [
			"final a = 1, b = 2; b = 3;",
			"final a = 1; a++;",
			"final a = 1; a += 2;",
			"final a = 1; var f = function() { a = 2; };",
			"final a = 1; if (true) a = 2;"
		]) {
			try {
				Frontend.compile("function main():Int { " + body + " return 0; }");
			} catch (error:CompileError) {
				if (error.diagnostic.code == "E1026")
					continue;
				throw error;
			}
			throw "Accepted a write to a final local: " + body;
		}
		Sys.println("PASS: local final declarations and immutable bindings");
	}
}
