import compiler.service.LanguageService;
import compiler.Diagnostic.CompileError;
import compiler.Source.SourceFile;
import compiler.syntax.Lexer;
import compiler.syntax.Parser;
import compiler.types.Typer;
import compiler.types.Type.NominalKind;

class ParserRecoveryMain {
	static function main():Void {
		var service = new LanguageService(),
			source = "class Box { public var value:Int; public function read():Int return value; } function main():Int { var box:Box = new Box(); box.value; box.";
		service.update("Main.hx", source);
		try
			service.analyze("Main")
		catch (_:CompileError) {}
		var completionResult = service.completeResult("Main.hx", source.length),
			completion = completionResult.items,
			names = [for (item in completion) item.label];
		if (!completionResult.isIncomplete)
			throw "recovered completion did not request a follow-up query";
		if (names.indexOf("value") < 0 || names.indexOf("read") < 0)
			throw "incomplete member access did not retain recovered receiver completion";
		for (item in completion)
			if ((item.label == "value" || item.label == "read") && item.stale)
				throw "recovered current completion was incorrectly marked stale";
		var boxDeclaration = source.indexOf("box:Box");
		if (service.hover("Main.hx", boxDeclaration + 1) != "box:Box")
			throw "recovered semantic model did not expose the current local type";
		var boxUse = source.lastIndexOf("box.");
		var definition = service.definition("Main.hx", boxUse + 1),
			references = service.references("Main.hx", boxUse + 1),
			rename = service.rename("Main.hx", boxUse + 1, "renamed"),
			highlights = service.documentHighlights("Main.hx", boxUse + 1);
		if (definition == null || definition.span.start != boxDeclaration || definition.stale)
			throw 'recovered local definition did not resolve to the current declaration: ${definition == null ? "null" : definition.span.start + ":" + definition.stale} expected $boxDeclaration';
		if (references.length < 2 || rename.length != 0 || highlights.length != references.length)
			throw "recovered local references, rename, or highlights were incomplete";
		var valueUse = source.lastIndexOf("value;"),
			valueDeclaration = source.indexOf("value:Int"),
			memberDefinition = service.definition("Main.hx", valueUse + 1);
		if (memberDefinition == null
			|| valueDeclaration < memberDefinition.span.start
			|| valueDeclaration > memberDefinition.span.end
			|| memberDefinition.stale)
			throw "recovered member definition did not resolve to the current field";

		var typeService = new LanguageService(),
			typeSource = "function main():Int { var unfinished:";
		typeService.update("Type.hx", typeSource);
		try
			typeService.analyze("Type")
		catch (_:CompileError) {}
		var locals = [for (item in typeService.complete("Type.hx", typeSource.length)) item.label];
		if (locals.indexOf("unfinished") < 0)
			throw "unfinished type annotation discarded its local declaration";

		for (tail in ["consume(", "values[", "true ?", "if (", "switch (", "(item:Int) ->"])
			assertNestedRecovery(tail);
		assertIncompleteDeclarations();
		assertPartialTypeFacts();
		assertTolerantTypedSnapshot();
		assertTruncationRecovery();
		Sys.println("PASS: incomplete member and type recovery support completion");
	}

	static function assertIncompleteDeclarations():Void {
		var parameterSource = new SourceFile("Parameter.hx", "function test(a:Int,");
		var parameterResult = new Parser(new Lexer(parameterSource).tokenize()).parseProgramRecovering();
		if (parameterResult.program.functions.length != 1
			|| parameterResult.program.functions[0].name != "test"
			|| parameterResult.program.functions[0].arguments.length != 1)
			throw "unfinished parameter list discarded the function declaration";

		var classSource = new SourceFile("Class.hx", "class Child extends");
		var classResult = new Parser(new Lexer(classSource).tokenize()).parseProgramRecovering();
		if (classResult.program.classes.length != 1 || classResult.program.classes[0].base == null)
			throw "unfinished extends clause discarded the class declaration";

		var methodSource = new SourceFile("Method.hx", "class Child { public function unfinished(");
		var methodResult = new Parser(new Lexer(methodSource).tokenize()).parseProgramRecovering();
		if (methodResult.program.classes.length != 1 || methodResult.program.classes[0].methods.length != 1
			|| methodResult.program.classes[0].methods[0].name != "unfinished")
			throw "unfinished method declaration discarded the class member";

		var genericSource = new SourceFile("Generic.hx", "function main():Void { var values:Array<");
		var genericResult = new Parser(new Lexer(genericSource).tokenize()).parseProgramRecovering();
		if (genericResult.program.functions.length != 1 || genericResult.program.functions[0].statements.length != 1)
			throw "unfinished generic type discarded the enclosing function";

		var memberSource = new SourceFile("Member.hx", "function main():Void return value.");
		var memberResult = new Parser(new Lexer(memberSource).tokenize()).parseProgramRecovering();
		if (memberResult.program.functions.length != 1 || memberResult.program.functions[0].statements.length != 1)
			throw 'unfinished member access discarded the function (${memberResult.program.functions.length}, ${memberResult.program.functions.length == 0 ? 0 : memberResult.program.functions[0].statements.length}): ${[for (diagnostic in memberResult.diagnostics) diagnostic.message].join("; ")}';
		switch memberResult.program.functions[0].statements[0] {
			case Return(Member(_, "", _), _):
			default:
				throw "unfinished member access did not retain a missing member node";
		}
	}

	static function assertPartialTypeFacts():Void {
		var expectedService = new LanguageService(),
			source = "class Foo {} function take(value:Foo):Void return; function main():Void return take(";
		expectedService.update("Expected.hx", source);
		var expectedModel = expectedService.compiler.modules.get("Expected").recoveredSemanticModel;
		if (expectedModel == null)
			throw "missing recovered semantic model for expected-type test";
		var expected = expectedModel.index.completionContext(source.length).expected;
		switch expected {
			case TInstance(NominalKind.Class, "Foo", _):
			default:
				throw 'unfinished call did not retain expected Foo argument type: $expected';
		}

		var errorService = new LanguageService(),
			errorSource = "function main():Void { var broken =";
		errorService.update("ErrorType.hx", errorSource);
		var errorModel = errorService.compiler.modules.get("ErrorType").recoveredSemanticModel;
		if (errorModel == null)
			throw "missing recovered semantic model for error-type test";
		var locals = errorModel.index.completionContext(errorSource.length).locals,
			foundError = false;
		for (local in locals)
			if (local.name == "broken")
				switch local.type {
					case TError: foundError = true;
					default:
				}
		if (!foundError)
			throw "incomplete initializer did not retain an explicit error type";

		var signatureService = new LanguageService(),
			signatureSource = "function take(value:Int):Void return; function main():Void return take(";
		signatureService.update("SignatureRecovery.hx", signatureSource);
		var signature = signatureService.signatureHelp("SignatureRecovery.hx", signatureSource.length);
		if (signature == null || signature.label != "take(value:Int):Void" || signature.activeParameter != 0)
			throw "recovered call did not expose signature help context";
	}

	static function assertNestedRecovery(tail:String):Void {
		var service = new LanguageService(),
			source = 'function consume(value:Int):Int return value; function main():Int { var available:Int = 1; var values = [1]; $tail';
		service.update("Nested.hx", source);
		try
			service.analyze("Nested")
		catch (_:CompileError) {}
		var names = [for (item in service.complete("Nested.hx", source.length)) item.label];
		if (names.indexOf("available") < 0)
			throw 'nested recovery discarded its enclosing function for "$tail"';
		if (service.diagnostics("Nested.hx").length > 20)
			throw 'nested recovery exceeded its diagnostic budget for "$tail"';
	}

	static function assertTolerantTypedSnapshot():Void {
		var source = new SourceFile("Tolerant.hx",
			"function main():Void { var first:Int = 1; broken.unresolved().thing; var second:Int = first; }");
		var recovered = new Parser(new Lexer(source).tokenize()).parseProgramRecovering().program,
			typed = Typer.typeRecovered(recovered);
		if (typed == null || typed.functions.length != 1)
			throw "tolerant typer did not produce a partial typed program";
		var functionBody = typed.functions[0].statements;
		if (functionBody.length != 3)
			throw 'tolerant typer discarded statements around an expression error: ${functionBody.length}';
		switch functionBody[2] {
			case TVar(name, _, _):
				if (name.indexOf(":second") < 0)
					throw 'tolerant typer retained the wrong local: $name';
			default:
				throw 'tolerant typer did not retain the local after an expression error: ${Type.enumConstructor(functionBody[2])}';
		}
	}

	static function assertTruncationRecovery():Void {
		var source = "package demo; class Box { public var value:Int; public function read(scale:Int):Int { if (scale > 0) return value * scale; return 0; } } function main():Int { var box:Box = new Box(); var values = [1, 2]; var read = (item:Int) -> item + box.value; return switch (values[0]) { case 1: read(41); default: 0; }; }";
		for (end in 0...source.length + 1) {
			var prefix = source.substring(0, end),
				file = new SourceFile("Truncated.hx", prefix);
			try {
				var recovered = new Parser(new Lexer(file).tokenize()).parseProgramRecovering();
				if (recovered.diagnostics.length > 20)
					throw 'recovery diagnostic budget exceeded at prefix $end';
			} catch (error:CompileError) {
				if (error.diagnostic.code != "E0001")
					throw 'recovering parser threw at prefix $end: ${error.diagnostic.message}';
			}
		}
		var errorFile = new SourceFile("ErrorNode.hx", "function main():Void { var incomplete ="),
			errorProgram = new Parser(new Lexer(errorFile).tokenize()).parseProgramRecovering().program;
		if (errorProgram.functions.length != 1)
			throw "error expression recovery discarded its function";
		switch errorProgram.functions[0].statements[0] {
			case VarDeclaration(_, _, ErrorExpression(_), _):
			default:
				throw "incomplete initializer did not produce an ErrorExpression";
		}
		var typeFile = new SourceFile("ErrorType.hx", "function main():Void { var incomplete:"),
			typeProgram = new Parser(new Lexer(typeFile).tokenize()).parseProgramRecovering().program;
		switch typeProgram.functions[0].statements[0] {
			case UninitializedDeclaration(_, ErrorType(_), _):
			default:
				throw "incomplete annotation did not produce an ErrorType";
		}
		var statementFile = new SourceFile("ErrorStatement.hx", "function main():Void { var = ; return; }"),
			statementProgram = new Parser(new Lexer(statementFile).tokenize()).parseProgramRecovering().program;
		switch statementProgram.functions[0].statements[0] {
			case ErrorStatement(_):
			default:
				throw "malformed statement did not produce an ErrorStatement";
		}
	}
}
