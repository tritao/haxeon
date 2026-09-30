import compiler.Frontend;
import compiler.Diagnostic.CompileError;

/** An error nobody catches is printed through `toString`, so that has to say where the problem is. */
class DiagnosticLocationMain {
	static function main():Void {
		try {
			Frontend.compile("function main():Int {\n  var x:Null<Int> = 1;\n  return x.foo;\n}");
		} catch (error:CompileError) {
			var text = Std.string(error);
			if (text != error.diagnostic.format())
				throw 'expected the located form, got "$text"';
			if (text.indexOf(":3:") < 0)
				throw 'expected the line of the offending expression in "$text"';
			Sys.println("PASS: uncaught compile errors carry their location");
			return;
		}
		throw "the source was expected not to compile";
	}
}
