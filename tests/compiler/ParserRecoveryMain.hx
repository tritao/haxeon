import compiler.service.LanguageService;
import compiler.service.CancellationError;
import compiler.service.CancellationToken;
import compiler.Diagnostic.CompileError;
import compiler.Diagnostic.DiagnosticOrigin;
import compiler.Source.SourceFile;
import compiler.syntax.Lexer;
import compiler.syntax.Parser;
import compiler.semantic.SemanticIndex.SemanticCompletionContextKind;
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
			typeSource = "class Foo {} function main():Int { var unfinished:";
		typeService.update("Type.hx", typeSource);
		try
			typeService.analyze("Type")
		catch (_:CompileError) {}
		var typeModel = typeService.compiler.modules.get("Type").recoveredSemanticModel,
			locals = [for (item in typeService.complete("Type.hx", typeSource.length)) item.label];
		if (typeModel == null || typeModel.index.completionContext(typeSource.length).kind != SemanticCompletionContextKind.Type)
			throw "unfinished type annotation did not expose a type completion context";
		if (locals.indexOf("Foo") < 0 || locals.indexOf("unfinished") >= 0)
			throw "type completion mixed value locals into an incomplete type annotation";

		for (tail in ["consume(", "values[", "true ?", "if (", "switch (", "(item:Int) ->"])
			assertNestedRecovery(tail);
		assertIncompleteDeclarations();
		assertPartialTypeFacts();
		assertTolerantTypedSnapshot();
		assertTolerantDeclarationSnapshot();
		assertRecoveryCancellation();
		assertDiagnosticOrigins();
		assertTruncationRecovery();
		Sys.println("PASS: incomplete member and type recovery support completion");
	}

	static function assertIncompleteDeclarations():Void {
		var missingFunctionName = new SourceFile("MissingFunction.hx", "function (");
		var missingFunctionResult = new Parser(new Lexer(missingFunctionName).tokenize()).parseProgramRecovering();
		if (missingFunctionResult.program.functions.length != 1 || missingFunctionResult.program.functions[0].name != "<missing>")
			throw "missing function name discarded the incomplete declaration";
		var placeholderService = new LanguageService();
		placeholderService.update("MissingFunction.hx", "function (");
		var placeholderModel = placeholderService.compiler.modules.get("MissingFunction").recoveredSemanticModel;
		if (placeholderModel == null)
			throw "missing-name recovery did not produce a semantic model";
		for (symbol in placeholderModel.index.symbols)
			if (symbol.name == "<missing>")
				throw "synthetic missing declaration leaked into semantic identity maps";

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

		var genericDeclarationSource = new SourceFile("GenericDeclaration.hx", "class Child<\nfunction main():Void return;");
		var genericDeclarationResult = new Parser(new Lexer(genericDeclarationSource).tokenize()).parseProgramRecovering();
		if (genericDeclarationResult.program.classes.length != 1
			|| genericDeclarationResult.program.classes[0].typeParameters.length != 1
			|| genericDeclarationResult.program.functions.length != 1)
			throw "unfinished generic declaration discarded adjacent declarations";

		var methodSource = new SourceFile("Method.hx", "class Child { public function unfinished(");
		var methodResult = new Parser(new Lexer(methodSource).tokenize()).parseProgramRecovering();
		if (methodResult.program.classes.length != 1
			|| methodResult.program.classes[0].methods.length != 1
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

		var blockSource = new SourceFile("Block.hx", "function main():Void if (condition) {");
		var blockResult = new Parser(new Lexer(blockSource).tokenize()).parseProgramRecovering();
		if (blockResult.program.functions.length != 1 || blockResult.program.functions[0].statements.length != 1)
			throw "unfinished block discarded the enclosing function";
		switch blockResult.program.functions[0].statements[0] {
			case If(_, thenBranch, _, _):
				if (thenBranch.length != 0)
					throw "unfinished block unexpectedly changed its statement shape";
			default:
				throw "unfinished block did not retain the conditional node";
		}

		var callSource = new SourceFile("Call.hx", "function main():Void return new Foo(");
		var callResult = new Parser(new Lexer(callSource).tokenize()).parseProgramRecovering();
		if (callResult.program.functions.length != 1 || callResult.program.functions[0].statements.length != 1)
			throw "unfinished constructor call discarded the enclosing function";

		var enumSource = new SourceFile("Enum.hx", "enum Choice {");
		var enumResult = new Parser(new Lexer(enumSource).tokenize()).parseProgramRecovering();
		if (enumResult.program.enums.length != 1)
			throw "unfinished enum declaration was abandoned at EOF";

		var controlSource = new SourceFile("Control.hx", "function main():Void { try { return; } for (");
		var controlResult = new Parser(new Lexer(controlSource).tokenize()).parseProgramRecovering();
		if (controlResult.program.functions.length != 1 || controlResult.program.functions[0].statements.length != 2)
			throw "unfinished try/for constructs discarded the enclosing function";
		switch controlResult.program.functions[0].statements[1] {
			case ForIn(_, _, ErrorExpression(_), _, _):
			default:
				throw "unfinished for construct did not retain its missing iterable";
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

		var assignmentService = new LanguageService(),
			assignmentSource = "class Foo {} function main():Void { var value:Foo = new Foo(); value = ";
		assignmentService.update("ExpectedAssignment.hx", assignmentSource);
		var assignmentModel = assignmentService.compiler.modules.get("ExpectedAssignment").recoveredSemanticModel;
		if (assignmentModel == null)
			throw "missing recovered semantic model for assignment expected-type test";
		var assignmentExpected = assignmentModel.index.completionContext(assignmentSource.length).expected;
		switch assignmentExpected {
			case TInstance(NominalKind.Class, "Foo", _):
			default:
				throw 'assignment did not retain expected Foo type: $assignmentExpected';
		}

		var returnService = new LanguageService(),
			returnSource = "class Foo {} function main():Foo return ";
		returnService.update("ExpectedReturn.hx", returnSource);
		var returnModel = returnService.compiler.modules.get("ExpectedReturn").recoveredSemanticModel;
		if (returnModel == null)
			throw "missing recovered semantic model for return expected-type test";
		var returnExpected = returnModel.index.completionContext(returnSource.length).expected;
		switch returnExpected {
			case TInstance(NominalKind.Class, "Foo", _):
			default:
				throw 'return did not retain expected Foo type: $returnExpected';
		}

		var collectionService = new LanguageService(),
			collectionSource = "class Foo {} function main():Void { var values:Array<Foo> = [";
		collectionService.update("ExpectedCollection.hx", collectionSource);
		var collectionModel = collectionService.compiler.modules.get("ExpectedCollection").recoveredSemanticModel;
		if (collectionModel == null)
			throw "missing recovered semantic model for collection expected-type test";
		var collectionExpected = collectionModel.index.completionContext(collectionSource.length).expected;
		switch collectionExpected {
			case TInstance(NominalKind.Class, "Foo", _):
			default:
				throw 'array literal did not retain expected Foo element type: $collectionExpected';
		}

		var objectService = new LanguageService(),
			objectSource = "class Foo {} typedef Options = { value:Foo }; function main():Void { var options:Options = { value: ";
		objectService.update("ExpectedObject.hx", objectSource);
		var objectModel = objectService.compiler.modules.get("ExpectedObject").recoveredSemanticModel;
		if (objectModel == null)
			throw "missing recovered semantic model for object-field expected-type test";
		var objectContext = objectModel.index.completionContext(objectSource.length);
		if (objectContext.kind != SemanticCompletionContextKind.ObjectField)
			throw 'object literal was classified as ${objectContext.kind} instead of ObjectField';
		switch objectContext.expected {
			case TInstance(NominalKind.Class, "Foo", _):
			default:
				throw 'object field did not retain expected Foo type: ${objectContext.expected}';
		}

		var importService = new LanguageService();
		importService.update("lib/Widget.hx", "class Widget {} function main():Void return;");
		try
			importService.analyze("lib.Widget")
		catch (_:CompileError) {}
		var importSource = "import Wid";
		importService.update("ImportRecovery.hx", importSource);
		var importModel = importService.compiler.modules.get("ImportRecovery").recoveredSemanticModel;
		if (importModel == null || importModel.index.completionContext(importSource.length).kind != SemanticCompletionContextKind.Import)
			throw "unfinished import did not expose an import completion context";
		var importNames = [
			for (item in importService.complete("ImportRecovery.hx", importSource.length))
				item.label
		];
		if (importNames.indexOf("Widget") < 0)
			throw "unfinished import did not expose an importable declaration";

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
					case TError:
						foundError = true;
					default:
				}
		if (!foundError)
			throw "incomplete initializer did not retain an explicit error type";

		var errorStatementSource = new SourceFile("ErrorStatementTyping.hx", "function main():Void { if () return; var after:Int = 1; }");
		var errorStatementProgram = new Parser(new Lexer(errorStatementSource).tokenize()).parseProgramRecovering().program,
			errorStatementTyped = Typer.typeRecovered(errorStatementProgram);
		if (errorStatementTyped == null
			|| errorStatementTyped.functions.length != 1
			|| errorStatementTyped.functions[0].statements.length < 2)
			throw "tolerant typing discarded a valid declaration after an ErrorStatement";

		var signatureService = new LanguageService(),
			signatureSource = "function take(value:Int):Void return; function main():Void return take(";
		signatureService.update("SignatureRecovery.hx", signatureSource);
		var signature = signatureService.signatureHelp("SignatureRecovery.hx", signatureSource.length);
		if (signature == null || signature.label != "take(value:Int):Void" || signature.activeParameter != 0)
			throw "recovered call did not expose signature help context";

		var interfaceService = new LanguageService(),
			interfaceSource = "class Foo {} interface Contract { function take(value:Foo):Void; } function main():Void { var contract:Contract; contract.take(";
		interfaceService.update("InterfaceRecovery.hx", interfaceSource);
		var interfaceSignature = interfaceService.signatureHelp("InterfaceRecovery.hx", interfaceSource.length);
		if (interfaceSignature == null || interfaceSignature.label != "take(value:Foo):Void" || interfaceSignature.activeParameter != 0)
			throw "recovered interface call did not expose signature help context";

		var navigationService = new LanguageService(),
			navigationSource = "function target():Void return; function main():Void return target(";
		navigationService.update("NavigationRecovery.hx", navigationSource);
		var targetDefinition = navigationService.definition("NavigationRecovery.hx", navigationSource.lastIndexOf("target(") + 1);
		var targetDeclaration = navigationSource.indexOf("target");
		if (targetDefinition == null || targetDefinition.span.start > targetDeclaration || targetDefinition.span.end < targetDeclaration)
			throw "recovered unfinished call did not resolve its current definition";
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
		var source = new SourceFile("Tolerant.hx", "function main():Void { var first:Int = 1; broken.unresolved().thing; var second:Int = first; }");
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
				throw "tolerant typer did not retain the local after an expression error";
		}

		var incompleteParameter = new SourceFile("TolerantParameter.hx", "function main(value:)");
		var parameterProgram = new Parser(new Lexer(incompleteParameter).tokenize()).parseProgramRecovering().program,
			parameterTyped = Typer.typeRecovered(parameterProgram);
		if (parameterTyped == null || parameterTyped.functions.length != 1 || parameterTyped.functions[0].arguments.length != 1)
			throw "tolerant typer abandoned a function with an incomplete parameter type";
		switch parameterTyped.functions[0].arguments[0].type {
			case TUnknown:
			default:
				throw "incomplete parameter type did not become TUnknown";
		}
	}

	static function assertTolerantDeclarationSnapshot():Void {
		var source = new SourceFile("TolerantDeclaration.hx", "class Child extends\nfunction main():Void return;");
		var recovered = new Parser(new Lexer(source).tokenize()).parseProgramRecovering().program,
			typed = Typer.typeRecovered(recovered);
		if (recovered.classes.length != 1)
			throw 'parser did not retain the incomplete class: classes=${recovered.classes.length}, functions=${recovered.functions.length}';
		if (typed == null)
			throw "tolerant typing abandoned a program with an incomplete inheritance clause";
		if (typed.classes.length != 1 || typed.functions.length != 1 || typed.functions[0].name != "main")
			throw 'tolerant typing discarded a valid declaration: classes=${typed.classes.length}, functions=${typed.functions.length}';

		var interfaceSource = new SourceFile("TolerantInterfaceDeclaration.hx", "interface Contract extends\nfunction main():Void return;");
		var interfaceRecovered = new Parser(new Lexer(interfaceSource).tokenize()).parseProgramRecovering().program,
			interfaceTyped = Typer.typeRecovered(interfaceRecovered);
		if (interfaceRecovered.interfaces.length != 1
			|| interfaceTyped == null
			|| interfaceTyped.interfaces.length != 1
			|| interfaceTyped.functions.length != 1)
			throw "tolerant typing abandoned a program with an incomplete interface inheritance clause";

		var implementsSource = new SourceFile("TolerantImplementsDeclaration.hx", "class Child implements\nfunction main():Void return;");
		var implementsRecovered = new Parser(new Lexer(implementsSource).tokenize()).parseProgramRecovering().program,
			implementsTyped = Typer.typeRecovered(implementsRecovered);
		if (implementsRecovered.classes.length != 1
			|| implementsTyped == null
			|| implementsTyped.classes.length != 1
			|| implementsTyped.functions.length != 1)
			throw "tolerant typing abandoned a program with an incomplete implements clause";

		var fieldSource = new SourceFile("TolerantFieldDeclaration.hx",
			"class Broken { var field:MissingType; public function visible():Void return; } function main():Void return;");
		var fieldRecovered = new Parser(new Lexer(fieldSource).tokenize()).parseProgramRecovering().program,
			fieldTyped = Typer.typeRecovered(fieldRecovered);
		if (fieldTyped == null
			|| fieldTyped.classes.length != 1
			|| fieldTyped.classes[0].methods.length != 1
			|| fieldTyped.functions.length != 2)
			throw 'tolerant typing discarded class methods after an invalid field type: ${fieldTyped == null ? "null" : "classes=" + fieldTyped.classes.length + ", methods=" + (fieldTyped.classes.length == 0 ? 0 : fieldTyped.classes[0].methods.length) + ", functions=" + fieldTyped.functions.length}';
		switch fieldTyped.classes[0].fields[0].type {
			case TUnknown:
			default:
				throw 'invalid field type was not represented as TUnknown: ${fieldTyped.classes[0].fields[0].type}';
		}
	}

	static function assertRecoveryCancellation():Void {
		var source = new SourceFile("CancelledRecovery.hx", "function main():Void { var first:Int = 1; var second:Int = first; }");
		var token = new CancellationToken();
		token.cancel();
		var cancelled = false;
		try
			Typer.typeRecovered(new Parser(new Lexer(source).tokenize()).parseProgramRecovering().program, null, token.check)
		catch (error:CancellationError)
			cancelled = true;
		if (!cancelled)
			throw "partial typing swallowed a cancelled recovery request";

		var checkpoints = 0;
		cancelled = false;
		try {
			new Parser(new Lexer(source).tokenize(), function() {
				if (++checkpoints == 2)
					throw new CancellationError();
			}).parseProgramRecovering();
		} catch (error:CancellationError)
			cancelled = true;
		if (!cancelled)
			throw "parser recovery did not honor its cancellation checkpoint";
	}

	static function assertDiagnosticOrigins():Void {
		var parserService = new LanguageService();
		parserService.update("ParserDiagnostic.hx", "function main():Void { var value:");
		var parserDiagnostics = parserService.diagnostics("ParserDiagnostic.hx");
		if (parserDiagnostics.length == 0 || parserDiagnostics[0].origin != DiagnosticOrigin.ParserRecovery)
			throw "recovery diagnostics did not retain parser provenance";
		try
			parserService.analyze("ParserDiagnostic")
		catch (_:CompileError) {}
		parserDiagnostics = parserService.diagnostics("ParserDiagnostic.hx");
		if (parserDiagnostics.length == 0 || parserDiagnostics[0].origin != DiagnosticOrigin.ParserRecovery)
			throw 'background analysis obscured parser recovery provenance: ${[for (diagnostic in parserDiagnostics) diagnostic.message + "/" + Std.string(diagnostic.origin)].join(", ")}';

		var semanticService = new LanguageService();
		semanticService.update("SemanticDiagnostic.hx", "function main():Int return \"wrong\";");
		try
			semanticService.analyze("SemanticDiagnostic")
		catch (_:CompileError) {}
		var semanticDiagnostics = semanticService.diagnostics("SemanticDiagnostic.hx");
		if (semanticDiagnostics.length == 0 || semanticDiagnostics[0].origin != DiagnosticOrigin.Semantic)
			throw 'type diagnostics were relabeled as recovery: ${[for (diagnostic in semanticDiagnostics) diagnostic.message + "/" + Std.string(diagnostic.origin)].join(", ")}';

		var lexicalService = new LanguageService();
		lexicalService.update("LexicalDiagnostic.hx", "function main():Void return \"");
		var lexicalDiagnostics = lexicalService.diagnostics("LexicalDiagnostic.hx");
		if (lexicalDiagnostics.length != 1 || lexicalDiagnostics[0].origin != DiagnosticOrigin.Lexical)
			throw "lexical recovery diagnostics did not retain lexical provenance";
		try
			lexicalService.analyze("LexicalDiagnostic")
		catch (_:CompileError) {}
		lexicalDiagnostics = lexicalService.diagnostics("LexicalDiagnostic.hx");
		if (lexicalDiagnostics.length != 1 || lexicalDiagnostics[0].origin != DiagnosticOrigin.Lexical)
			throw "background analysis obscured lexical provenance";
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
			case VarDeclaration("<missing>", _, ErrorExpression(_), _):
			default:
				throw "malformed local declaration did not preserve a missing name and expression";
		}
	}
}
