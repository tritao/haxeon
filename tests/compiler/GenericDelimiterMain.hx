import compiler.Compiler;
import compiler.Diagnostic.CompileError;
import compiler.Source.SourceFile;
import compiler.syntax.Lexer;
import compiler.syntax.Parser;
import compiler.syntax.Token.TokenKind;
import compiler.hl.HlWriter;
import sys.io.File;

/** Source strings intentionally omit whitespace: formatting this test must not hide the regression. */
class GenericDelimiterMain {
	static function main():Void {
		for (source in [
			"class Part {} function main():Int { var parts:Array<Part>=[]; return 42; }",
			"function main():Int { var grid:Array<Array<Int>>=[[42]]; return grid[0][0]; }",
			"function main():Int { var values:Map<String,Array<Int>>=[]; values.set(\"answer\",[42]); return values.get(\"answer\")[0]; }",
			"function main():Int { var values:Null<Array<Int>>=[42]; return values == null ? 0 : values[0]; }",
			"typedef Parts<T>=Array<T>; function main():Int { var parts:Parts<Int>=[42]; return parts[0]; }",
			"class Holder { public var parts:Array<Int>=[42]; public static final nested:Array<Array<Int>>=[[42]]; public function new() {} } function main():Int return new Holder().parts[0];",
			"function first(parts:Array<Int>=[42]):Int return parts[0]; function main():Int return first();",
			"function main():Int { var parts:Array<Int>=[42]; var deeper:Array<Array<Array<Int>>>=[[[42]]]; return parts[0]+deeper[0][0][0]-42; }"
		]) {
			var compiler = new Compiler();
			for (revision in 0...3) {
				// Move between compact and spaced delimiters before changing the value.
				compiler.update("Main.hx",
					revision == 1 ? StringTools.replace(source, ">=", "> =") : revision == 2 ? StringTools.replace(source, "42", "43") : source);
				var result = compiler.compile("Main"),
					value = execute(HlWriter.encode(result.module));
				if (value != (revision == 2 ? 43 : 42))
					throw 'Generic delimiter returned $value (revision=$revision): $source';
			}
		}
		var operators = "function main():Int { var x=64; x>>=2; if (x!=16) return 1; x<<=1; if(x!=32) return 2; var u=-1; u>>>=28; if(u!=15) return 3; if (!(x>=32) || !(x >= 31) || x>32 || !(x>>2==8) || !(u>>>1==7)) return 4; return 42; }";
		var compiler = new Compiler();
		compiler.update("Main.hx", operators);
		if (execute(HlWriter.encode(compiler.compile("Main").module)) != 42)
			throw "Comparison or shift operators changed";
		var file = new SourceFile("Tokens.hx", "// é\ntypedef Parts<T>=Array<T>; function main():Int { var parts:Array<Int>=[]; return 1>=0 ? 42 : 0; }");
		var tokens = new Lexer(file).tokenize(), saved = tokens.copy();
		for (_ in 0...2)
			new Parser(tokens).parseProgram();
		if (tokens.length != saved.length)
			throw "Parser changed lexer token count";
		var comparisons = 0;
		for (i in 0...tokens.length) {
			if (tokens[i] != saved[i])
				throw "Parser changed cached lexer tokens";
			if (tokens[i].kind == GreaterEqual)
				comparisons++;
		}
		if (comparisons != 3)
			throw "Lexer must retain >= tokens";
		for (source in [
			"function main():Int { return 2 > = 1 ? 42 : 0; }",
			"function main():Int { var x=8; x >> = 1; return x; }",
			"function main():Int { var x=8; x >>> = 1; return x; }"
		])
			reject(source);
		for (source in [
			"typedef Parts<T:Part>=Array<T>;",
			"function main():Void { var pointer:native_pointer<\"slot\">=null; }",
			"function main():Void { var build:()->Array<Int>=()->[]; }"
		])
			parse(source);
		var recoveredFile = new SourceFile("Recovery.hx", "function main():Int { var bad:Array<Int>=; var good:Array<Int>=[]; return 42; }");
		var recovered = new Parser(new Lexer(recoveredFile).tokenize()).parseProgramRecovering();
		if (recovered.diagnostics.length != 1 || recovered.program.functions.length != 1)
			throw "Generic delimiter recovery lost subsequent source";
		var retained = false;
		for (statement in recovered.program.functions[0].statements)
			switch statement {
				case VarDeclaration("good", _, _, _):
					retained = true;
				default:
			}
		if (!retained)
			throw "Generic delimiter recovery discarded the following valid declaration";
		var malformed = "// é\nfunction main():Int { var parts:Array<Int>=; return 0; }";
		try {
			parse(malformed);
			throw "Missing initializer parsed";
		} catch (error:CompileError) {
			var file = new SourceFile("Main.hx", malformed);
			if (error.diagnostic.span.start != file.byteOffsetForStringOffset(malformed.indexOf(";")))
				throw "Splitting the delimiter lost the diagnostic byte offset";
		}
		Sys.println("PASS: generic closing delimiters next to assignment, incremental builds and operator token boundaries");
	}

	static function execute(bytes:haxe.io.Bytes):Int {
		var path = "out/generic-delimiter-main.hl";
		File.saveBytes(path, bytes);
		var child = new sys.io.Process(".tools/hashlink/hl", [path]);
		var output = child.stdout.readAll().toString() + child.stderr.readAll().toString(),
			code = child.exitCode();
		child.close();
		if (code != 42 && code != 43)
			throw 'Generic delimiter program returned $code: $output';
		return code;
	}

	static function parse(source:String):Void
		new Parser(new Lexer(new SourceFile("Main.hx", source)).tokenize()).parseProgram();

	static function reject(source:String):Void {
		try {
			parse(source);
		} catch (_:CompileError) {
			return;
		}
		throw 'Separated operator tokens unexpectedly parsed: $source';
	}
}
