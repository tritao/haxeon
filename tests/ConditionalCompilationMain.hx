import compiler.Diagnostic.CompileError;
import compiler.Source.SourceFile;
import compiler.syntax.ConditionalCompilation;
import compiler.syntax.Lexer;
import compiler.syntax.Parser;

/** Exercises inline conditional directives and Haxe-style version conditions. */
class ConditionalCompilationMain {
	static function main():Void {
		var source = "typedef Choice = #if (haxe >= version(\"4.2.0\") && (hl || sys)) Int #elseif fallback String #else Bool #end;\n"
			+ "function main():Choice return #if disabled 0 #else 42 #end;",
			processed = process(source, ["haxe" => "4.10.0", "hl" => "1"]);
		if (processed.length != source.length || processed.indexOf("Int") < 0 || processed.indexOf("42") < 0 || processed.indexOf("String") >= 0)
			throw "inline conditional branches were not selected or offset-preserved";
		new Parser(new Lexer(new SourceFile("Inline.hx", source), processed).tokenize()).parseProgram();

		var older = process("typedef Choice = #if (haxe >= version(\"4.10.0\")) Int #else String #end;", ["haxe" => "4.3.7"]);
		if (older.indexOf("String") < 0 || older.indexOf("Int") >= 0)
			throw "dotted versions were not compared component by component";

		var literal = "function css():String return '#utesttip { color: #fff; }'; // #error ignored\n/* #if ignored */";
		if (process(literal, []) != literal)
			throw "directive-like text in strings or comments was modified";

		process("#if disabled\n#error inactive\n#end\nfunction main():Int return 42;", []);
		expectError("#unknown value", "Unknown conditional directive #unknown");
		expectError("#if enabled\n#error \"selected branch failed\"\n#end", "selected branch failed", ["enabled" => "1"]);
		Sys.println("PASS: inline conditional compilation, #error, and version conditions");
	}

	static function expectError(source:String, message:String, ?defines:Map<String, String>):Void {
		try {
			process(source, defines == null ? [] : defines);
			throw 'conditional source did not fail with "$message"';
		} catch (error:CompileError) {
			if (error.diagnostic.code != "E0002" || error.diagnostic.message != message)
				throw error;
		}
	}

	static function process(source:String, defines:Map<String, String>):String {
		var file = new SourceFile("Conditional.hx", source);
		return ConditionalCompilation.process(file, defines).text;
	}
}
