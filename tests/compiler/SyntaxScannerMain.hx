import compiler.Source.SourceFile;
import compiler.syntax.Lexer;
import compiler.syntax.SyntaxScanner;
import compiler.syntax.SyntaxScanner.SyntaxTokenKind;

/** Regression gates for the shared lossless scanner and compiler adapter. */
class SyntaxScannerMain {
	static function main():Void {
		var source = "function main():String {\r\n"
			+ "\tvar value = 'text ${1 + 2}'; // line\r\n"
			+ "\tvar pattern = ~/a[//]b/gi; /* block */\r\n"
			+ "\treturn value;\r\n"
			+ "}\r\n",
			file = new SourceFile("SyntaxScanner.hx", source),
			lossless = new SyntaxScanner(file).scan(),
			cursor = 0,
			syntaxCount = 0,
			triviaCount = 0;

		for (token in lossless) {
			if (token.span.start != cursor)
				throw 'lossless scanner left a gap at $cursor';
			cursor = token.span.end;
			switch token.kind {
				case SyntaxTokenKind.Syntax(_): syntaxCount++;
				default: triviaCount++;
			}
		}
		if (cursor != file.bytes.length || syntaxCount == 0 || triviaCount == 0)
			throw "lossless scanner did not cover syntax and trivia";

		var roundTrip = new StringBuf();
		for (token in lossless)
			roundTrip.add(token.text);
		if (roundTrip.toString() != source)
			throw "lossless scanner changed source bytes";

		var compilerTokens = new Lexer(file).tokenize(),
			compilerMode = new SyntaxScanner(file, null, null, true, false).scan(),
			compilerIndex = 0;
		for (token in compilerMode)
			switch token.kind {
				case SyntaxTokenKind.Syntax(kind):
					var compilerToken = compilerTokens[compilerIndex++];
					if (compilerToken.kind != kind || compilerToken.text != token.text)
						throw "compiler adapter changed syntax token sequence";
				default:
					throw "compiler scanner mode retained trivia";
			}
		if (compilerTokens[compilerIndex].kind != compiler.syntax.Token.TokenKind.Eof)
			throw "compiler adapter did not terminate at EOF";

		var directiveSource = new SourceFile("Directives.hx", "#if debug\nfunction main():Void return;\n#end\n"),
			directiveTokens = new SyntaxScanner(directiveSource).scan(),
			directives = 0;
		for (token in directiveTokens)
			if (token.kind == SyntaxTokenKind.Directive)
				directives++;
		if (directives != 2)
			throw "lossless scanner did not retain directives";

		Sys.println("PASS: shared lossless scanner preserves source and compiler parity");
	}
}
