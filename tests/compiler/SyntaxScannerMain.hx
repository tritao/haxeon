import compiler.Source.SourceFile;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstProgram;
import compiler.syntax.Ast.AstStatement;
import compiler.syntax.Ast.AstType;
import compiler.syntax.Lexer;
import compiler.syntax.Parser;
import compiler.syntax.SyntaxScanner;
import compiler.syntax.SyntaxScanner.SyntaxTokenKind;
import compiler.syntax.SyntaxTree.ParserMode;
import compiler.syntax.SyntaxTree.SyntaxKind;
import compiler.syntax.SyntaxTree.SyntaxNodePayload;

/** Regression gates for the shared lossless scanner, CST, and AST adapter. */
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
		if (haxe.Serializer.run(cstProgram) != haxe.Serializer.run(astOnlyProgram))
			throw "CST parser mode changed the complete semantic AST";
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

		var expressionSource = new SourceFile("Expressions.hx",
			"function main(value:Int):Int { var result = value + 1; var nested = result = value; return object.field + result > 0 ? result : 0; }\n"),
			expressionParser = new Parser(new Lexer(expressionSource).tokenize(), null, ParserMode.Cst(expressionSource));
		expressionParser.parseProgram();
		var expressionKinds:Map<SyntaxKind, Bool> = [];
		for (node in expressionParser.cst.grammarNodes())
			expressionKinds.set(node.kind, true);
		if (!expressionKinds.exists(SyntaxKind.BinaryExpression)
			|| !expressionKinds.exists(SyntaxKind.ConditionalExpression)
			|| !expressionKinds.exists(SyntaxKind.AssignmentExpression)
			|| !expressionKinds.exists(SyntaxKind.MemberExpression))
			throw "CST parser did not retain expression-level grammar structure";

		var payloadSource = new SourceFile("ExpressionPayloads.hx",
			"function payloads(value:Int):Int { "
			+ "var list = new List<Int>(); var array = new Array<Int>(1); var map = new Map<String, Int>(); "
			+ "var values = [value, value + 1]; var entries = [value => value + 1]; var object = {field: value}; "
			+ "var casted = cast(value, Int); var fn = function(x:Int) { return x + value; }; "
			+ "var arrow = (x:Int) -> x + value; return switch (value) { case 0: value; default: value + 1; }; }\n");
		assertCstAstParity("ExpressionPayloads.hx", payloadSource.text, false);

		var headerSource = new SourceFile("Header.hx",
			"package demo.core;\nimport foo.Bar as Baz;\nfunction main():Void return;\n"),
			headerAst = new Parser(new Lexer(headerSource).tokenize()).parseProgram(),
			headerParser = new Parser(new Lexer(headerSource).tokenize(), null, ParserMode.Cst(headerSource)),
			headerCstAst = headerParser.parseProgram();
		if (programShape(headerCstAst) != programShape(headerAst))
			throw "CST lowerer changed the source header AST shape";

		var emptyClassSource = new SourceFile("EmptyClass.hx", "class Empty {}\n"),
			emptyClassParser = new Parser(new Lexer(emptyClassSource).tokenize(), null, ParserMode.Cst(emptyClassSource)),
			emptyClassProgram = emptyClassParser.parseProgram();
		if (emptyClassProgram.classes.length != 1 || emptyClassProgram.classes[0].name != "Empty"
			|| emptyClassProgram.classes[0].fields.length != 0 || emptyClassProgram.classes[0].methods.length != 0)
			throw "CST lowerer did not preserve an empty class declaration";

		var genericClassSource = new SourceFile("GenericClass.hx", "class Generic<T> extends Base implements Readable, Writable {}\n"),
			genericClassParser = new Parser(new Lexer(genericClassSource).tokenize(), null, ParserMode.Cst(genericClassSource)),
			genericClassProgram = genericClassParser.parseProgram(),
			genericClass = genericClassProgram.classes[0];
		if (genericClass.typeParameters.length != 1 || genericClass.typeParameters[0] != "T"
			|| genericClass.base == null || genericClass.interfaces.length != 2)
			throw "CST lowerer did not preserve generic class inheritance";

		var declarationSource = new SourceFile("Declarations.hx",
			"typedef Alias<T:Base> = Array<T>; enum Choice<T:Base> { None; Some(value:T); } "
			+ "enum abstract Flags(Int) from Int to Int { var Ready = 1; } "
			+ "abstract Box<T:Base>(T) { public function get():Int return 1; } "
			+ "class Holder<T:Base> extends Parent<T> implements Readable<T>, Writable<T> { public var value:Int; public function empty():Int {} public function read():Int return value + 1; "
			+ "public function choose(flag:Bool):Int if (flag) return value + 1; else return value; "
			+ "public function loop(flag:Bool):Void while (flag) break; "
			+ "public function doLoop(flag:Bool):Void do { break; } while (flag); "
			+ "public function each(values:Int):Void for (value in values) break; "
			+ "public function control(value:Int):Int { var local = value; local += 1; "
			+ "try { switch (local) { case 0: return 1; default: return local; } } "
			+ "catch (error:Error) { return 0; } } } "
			+ "function generic<T:Base>(value:T):T return value;\n"
			+ "interface Reader<T:Base> extends Readable<T> { function read(value:Int):String; }\n"),
			declarationParser = new Parser(new Lexer(declarationSource).tokenize(), null, ParserMode.Cst(declarationSource));
		var declarationProgram = declarationParser.parseProgram();
		if (declarationParser.cst == null)
			throw "CST declaration parser did not retain a tree";
		if (declarationProgram.aliases.length != 1 || declarationProgram.enums.length != 1 || declarationProgram.enumAbstracts.length != 1
			|| declarationProgram.abstracts.length != 1 || declarationProgram.aliases[0].name != "Alias"
			|| declarationProgram.enums[0].cases.length != 2 || declarationProgram.enumAbstracts[0].values.length != 1
			|| declarationProgram.abstracts[0].methods.length != 1 || declarationProgram.functions.length != 1)
			throw "CST lowerer did not preserve declaration payloads";
		if (declarationProgram.aliases[0].typeConstraints.length != 1
			|| declarationProgram.enums[0].typeConstraints.length != 1
			|| declarationProgram.abstracts[0].typeConstraints.length != 1
			|| declarationProgram.classes[0].typeConstraints.length != 1
			|| declarationProgram.interfaces[0].typeConstraints.length != 1
			|| declarationProgram.functions[0].typeConstraints.length != 1)
			throw "CST lowerer did not preserve generic type constraints";
		var parserOwnedHeaderPayloads = 0;
		for (node in declarationParser.cst.grammarNodes())
			switch node.payload {
				case SyntaxNodePayload.ClassHeaderRich(_, _, _, _, _, _, _),
					SyntaxNodePayload.EnumHeader(_, _, _, _),
					SyntaxNodePayload.EnumAbstractHeader(_, _, _, _, _),
					SyntaxNodePayload.AbstractHeader(_, _, _, _, _, _, _),
					SyntaxNodePayload.InterfaceHeader(_, _, _, _):
					parserOwnedHeaderPayloads++;
				default:
			}
		if (parserOwnedHeaderPayloads < 5)
			throw "CST declaration headers were not retained as parser-owned payloads";
		var hasForStatement = false, hasVariableDeclaration = false, hasAssignment = false, hasTry = false, hasSwitch = false;
		for (node in declarationParser.cst.grammarNodes())
			switch node.kind {
				case SyntaxKind.ForStatement: hasForStatement = true;
				case SyntaxKind.VariableDeclaration: hasVariableDeclaration = true;
				case SyntaxKind.AssignmentStatement: hasAssignment = true;
				case SyntaxKind.TryStatement: hasTry = true;
				case SyntaxKind.SwitchStatement: hasSwitch = true;
				default:
			}
		if (!hasForStatement || !hasVariableDeclaration || !hasAssignment || !hasTry || !hasSwitch)
			throw "CST parser did not retain all compound statements";
		var holder = declarationProgram.classes[0], reader = declarationProgram.interfaces[0];
		if (holder.fields.length != 1 || holder.fields[0].name != "value" || holder.fields[0].initializer != null
			|| holder.methods.length != 7 || holder.methods[0].name != "empty" || holder.methods[0].statements.length != 0
			|| holder.methods[1].statements.length != 1
			|| holder.methods[2].name != "choose" || holder.methods[2].statements.length != 1
			|| holder.methods[3].name != "loop" || holder.methods[3].statements.length != 1
			|| holder.methods[4].name != "doLoop" || holder.methods[4].statements.length != 1
			|| holder.methods[5].name != "each" || holder.methods[5].statements.length != 1
			|| holder.methods[6].name != "control" || holder.methods[6].statements.length != 3
			|| reader.methods.length != 1 || reader.methods[0].arguments.length != 1 || reader.methods[0].arguments[0].name != "value")
			throw "CST lowerer did not preserve field and function signatures";
		switch holder.methods[1].statements[0] {
			case Return(Add(Variable(name, _), IntegerLiteral(value, _), _), _):
				if (name != "value" || value != 1)
					throw "CST lowerer changed a compound return expression";
			default: throw "CST lowerer did not lower a compound return statement";
		}
		switch holder.methods[2].statements[0] {
			case AstStatement.If(condition, thenBranch, elseBranch, _):
				switch condition {
					case Variable(name, _):
						if (name != "flag")
							throw "CST lowerer changed an if condition";
					default: throw "CST lowerer did not lower an if condition";
				}
				if (thenBranch.length != 1 || elseBranch.length != 1)
					throw "CST lowerer changed if branches";
			default: throw "CST lowerer did not lower an if statement";
		}
		switch holder.methods[3].statements[0] {
			case AstStatement.While(_, body, _):
				if (body.length != 1)
					throw "CST lowerer changed a while body";
			default: throw "CST lowerer did not lower a while statement";
		}
		switch holder.methods[4].statements[0] {
			case AstStatement.DoWhile(body, _, _):
				if (body.length != 1)
					throw "CST lowerer changed a do-while body";
			default: throw "CST lowerer did not lower a do-while statement";
		}
		switch holder.methods[5].statements[0] {
			case AstStatement.ForIn(keyName, valueName, AstExpression.Variable(iterableName, _), body, _):
				if (keyName != "value" || valueName != null || iterableName != "values" || body.length != 1)
					throw "CST lowerer changed a for-in statement";
			default: throw "CST lowerer did not lower a for-in statement";
		}
		switch holder.methods[6].statements[2] {
			case AstStatement.Try(tryBranch, catches, _):
				if (tryBranch.length != 1 || catches.length != 1 || catches[0].name != "error" || catches[0].statements.length != 1)
					throw "CST lowerer changed a try/catch statement";
				switch tryBranch[0] {
					case AstStatement.Switch(_, cases, defaultBranch, hasDefault, _):
						if (cases.length != 1 || defaultBranch.length != 1 || !hasDefault)
							throw "CST lowerer changed a switch statement";
					default: throw "CST lowerer did not lower a switch statement";
				}
			default: throw "CST lowerer did not lower a try/catch statement";
		}
		switch holder.fields[0].type {
			case IntType:
			default: throw "CST lowerer changed a simple field type";
		}
		switch reader.methods[0].result {
			case StringType:
			default: throw "CST lowerer changed an interface method result type";
		}

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
		assertCstAstParity("SyntaxScanner.hx", source, false);
		assertCstAstParity("Expressions.hx", expressionSource.text, false);
		assertCstAstParity("Declarations.hx", declarationSource.text, false);
		assertCstAstParity("GenericClass.hx", genericClassSource.text, false);
		assertCstAstParity("MalformedSyntax.hx", malformed.text, true);
		assertCstAstParity("MalformedTail.hx",
			"class Broken { public function before():Int return 1; public function unfinished(a:Int { return 2; } public function after():Int return 3; }",
			true);

		var directiveSource = new SourceFile("Directives.hx", "#if debug\nfunction main():Void return;\n#end\n"),
			directiveTokens = new SyntaxScanner(directiveSource).scan(),
			directives = 0;
		for (token in directiveTokens)
			if (token.kind == SyntaxTokenKind.Directive)
				directives++;
		if (directives != 2)
			throw "lossless scanner did not retain directives";

		Sys.println("PASS: shared lossless scanner, CST, and AST parity");
	}

	static function assertCstAstParity(path:String, source:String, recovering:Bool):Void {
		var file = new SourceFile(path, source),
			directParser = new Parser(new Lexer(file).tokenize()),
			cstParser = new Parser(new Lexer(file).tokenize(), null, ParserMode.Cst(file)),
			directProgram:AstProgram,
			cstProgram:AstProgram,
			directDiagnostics:Array<compiler.Diagnostic> = [],
			cstDiagnostics:Array<compiler.Diagnostic> = [];
		if (recovering) {
			var direct = directParser.parseProgramRecovering(), cst = cstParser.parseProgramRecovering();
			directProgram = direct.program;
			cstProgram = cst.program;
			directDiagnostics = direct.diagnostics;
			cstDiagnostics = cst.diagnostics;
		} else {
			directProgram = directParser.parseProgram();
			cstProgram = cstParser.parseProgram();
		}
		var tree = cstParser.cst;
		if (tree == null || tree.roundTrip() != source)
			throw 'CST parity tree did not round-trip $path';
		if (haxe.Serializer.run(cstProgram) != haxe.Serializer.run(directProgram))
			throw 'CST lowering changed the complete AST for $path';
		if (haxe.Serializer.run(cstDiagnostics) != haxe.Serializer.run(directDiagnostics))
			throw 'CST lowering changed recovery diagnostics for $path';
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
