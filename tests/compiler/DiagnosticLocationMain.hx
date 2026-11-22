import compiler.Compiler;
import compiler.Frontend;
import compiler.core.Diagnostic.CompileError;
import compiler.runtime.CompilerIntrinsics;

/** An error nobody catches is printed through `toString`, so that has to say where the problem is. */
class DiagnosticLocationMain {
	static function main():Void {
		uncaughtErrorIsLocated();
		missingEntryPointIsInTheEntryModule();
	}

	static function uncaughtErrorIsLocated():Void {
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

	/** A program without `main` is reported at the entry module's type of its name, as Haxe reports `-main Main` at class Main. */
	static function missingEntryPointIsInTheEntryModule():Void {
		for (source in [
			{text: "class Helper {}\nclass Main {\n\tstatic function helper() {}\n}\n", at: "class Main"},
			{text: "import haxe.ds.Option;\n\nfunction helper() {}\n", at: "function helper"},
			{text: "", at: ""}
		]) {
			var c = new Compiler();
			CompilerIntrinsics.register(c);
			c.addStandardLibrarySourceRoot("stdlib");
			c.update("Main.hx", source.text);
			try {
				c.compile("Main");
			} catch (error:CompileError) {
				var span = error.diagnostic.span;
				if (error.diagnostic.message != 'Program must define executable entry point "main"')
					throw 'unexpected error "${error.diagnostic.format()}"';
				if (span.file.path != "Main.hx" || span.start != source.text.indexOf(source.at))
					throw 'expected the missing entry point at "${source.at}" of Main.hx, got ${error.diagnostic.format()}';
				continue;
			}
			throw "a program without main was expected not to compile";
		}
		Sys.println("PASS: a missing entry point is reported in the entry module");
	}
}
