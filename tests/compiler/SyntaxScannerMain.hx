import compiler.Source.SourceFile;
import compiler.syntax.Ast.AstProgram;
import compiler.syntax.Lexer;
import compiler.syntax.Parser;
import compiler.syntax.SyntaxScanner;
import compiler.syntax.SyntaxScanner.SyntaxTokenKind;
import compiler.syntax.SyntaxTree.ParserMode;
import compiler.syntax.SyntaxTree.SyntaxKind;

/** Regression gates for the shared lossless scanner and compiler adapter. */
class SyntaxScannerMain {
	static function main():Void {
		var source = "function main():String {\r\n"
			+ "\tvar value = 'text ${1 + 2}'; // line\r\n"
			+ "\tvar pattern = ~/a[//]b/gi; /* block */\r\n"
			+ "\tvar item = new Box<Int>();\r\n"
			+ "\tvar values = [1, 2];\r\n"
			+ "\tvar record = {value: value};\r\n"
			+ "\treturn value.trim();\r\n"
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

		var astOnlyParser = new Parser(compilerTokens),
			astOnlyProgram = astOnlyParser.parseProgram();
		if (astOnlyParser.cst != null)
			throw "default parser mode retained a CST";
		var cstParser = new Parser(compilerTokens, null, ParserMode.Cst(file)),
			cstProgram = cstParser.parseProgram(),
			cst = cstParser.cst;
		if (cst == null || cst.roundTrip() != source)
			throw "CST mode did not round-trip the valid source";
		if (cst.root.span.start != 0 || cst.root.span.end != file.bytes.length || cst.tokens.length != syntaxCount)
			throw "CST mode did not preserve source spans or syntax tokens";
		if (programShape(cstProgram) != programShape(astOnlyProgram))
			throw "CST parser mode changed the semantic AST shape";
		var grammarKinds:Map<SyntaxKind, Bool> = [];
		for (node in cst.grammarNodes())
			grammarKinds.set(node.kind, true);
		if (!grammarKinds.exists(SyntaxKind.FunctionDeclaration)
			|| !grammarKinds.exists(SyntaxKind.Block)
			|| !grammarKinds.exists(SyntaxKind.CallExpression)
			|| !grammarKinds.exists(SyntaxKind.ArgumentList)
			|| !grammarKinds.exists(SyntaxKind.ParameterList)
			|| !grammarKinds.exists(SyntaxKind.TypeArgumentList)
			|| !grammarKinds.exists(SyntaxKind.ArrayLiteral)
			|| !grammarKinds.exists(SyntaxKind.ObjectLiteral))
			throw "CST parser mode did not retain grammar-level structure";

		var malformed = new SourceFile("MalformedSyntax.hx", "function unfinished(a:Int {\n  // keep this\n  return 1;\n"),
			malformedParser = new Parser(new Lexer(malformed).tokenize(), null, ParserMode.Cst(malformed));
		malformedParser.parseProgramRecovering();
		if (malformedParser.cst == null || malformedParser.cst.roundTrip() != malformed.text)
			throw "CST mode did not round-trip malformed source";
		if (malformedParser.cst.syntheticTokens.length == 0)
			throw "CST recovery did not retain a synthetic missing token";
		var malformedKinds:Map<SyntaxKind, Bool> = [];
		for (node in malformedParser.cst.grammarNodes())
			malformedKinds.set(node.kind, true);
		if (!malformedKinds.exists(SyntaxKind.Error) || !malformedKinds.exists(SyntaxKind.Missing))
			throw "CST recovery did not retain explicit error/missing structure";

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

	static function programShape(program:AstProgram):String {
		var shape:Array<String> = ["package=" + (program.packageName == null ? "" : program.packageName)];
		for (path in program.imports)
			shape.push("import=" + path);
		for (alias in program.aliases)
			shape.push('alias=${alias.name}:${alias.span.start}:${alias.span.end}');
		for (functionDeclaration in program.functions)
			shape.push('function=${functionDeclaration.name}:${functionDeclaration.span.start}:${functionDeclaration.span.end}:args=${functionDeclaration.arguments.length}:statements=${functionDeclaration.statements.length}');
		for (classDeclaration in program.classes) {
			shape.push('class=${classDeclaration.name}:${classDeclaration.span.start}:${classDeclaration.span.end}:fields=${classDeclaration.fields.length}:methods=${classDeclaration.methods.length}');
			for (method in classDeclaration.methods)
				shape.push('method=${method.name}:${method.span.start}:${method.span.end}:args=${method.arguments.length}:statements=${method.statements.length}');
		}
		for (interfaceDeclaration in program.interfaces)
			shape.push('interface=${interfaceDeclaration.name}:${interfaceDeclaration.span.start}:${interfaceDeclaration.span.end}:methods=${interfaceDeclaration.methods.length}');
		for (enumeration in program.enums)
			shape.push('enum=${enumeration.name}:${enumeration.span.start}:${enumeration.span.end}:cases=${enumeration.cases.length}');
		return shape.join("|");
	}
}
