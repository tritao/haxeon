import compiler.service.LanguageService;
import compiler.Diagnostic.CompileError;
import compiler.Source.SourceFile;
import compiler.syntax.Lexer;
import compiler.syntax.Parser;

class ParserRecoveryMain {
	static function main():Void {
		var service = new LanguageService(), source =
			"class Box { public var value:Int; public function read():Int return value; } function main():Int { var box:Box = new Box(); box.";
		service.update("Main.hx", source);
		try
			service.analyze("Main")
		catch (_:CompileError) {}
		var names = [for (item in service.complete("Main.hx", source.length)) item.label];
		if (names.indexOf("value") < 0 || names.indexOf("read") < 0)
			throw "incomplete member access did not retain recovered receiver completion";

		var typeService = new LanguageService(), typeSource = "function main():Int { var unfinished:";
		typeService.update("Type.hx", typeSource);
		try
			typeService.analyze("Type")
		catch (_:CompileError) {}
		var locals = [for (item in typeService.complete("Type.hx", typeSource.length)) item.label];
		if (locals.indexOf("unfinished") < 0)
			throw "unfinished type annotation discarded its local declaration";

		for (tail in ["consume(", "values[", "true ?", "if (", "switch (", "(item:Int) ->"])
			assertNestedRecovery(tail);
		assertTruncationRecovery();
		Sys.println("PASS: incomplete member and type recovery support completion");
	}

	static function assertNestedRecovery(tail:String):Void {
		var service = new LanguageService(), source = 'function consume(value:Int):Int return value; function main():Int { var available:Int = 1; var values = [1]; $tail';
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

	static function assertTruncationRecovery():Void {
		var source = "package demo; class Box { public var value:Int; public function read(scale:Int):Int { if (scale > 0) return value * scale; return 0; } } function main():Int { var box:Box = new Box(); var values = [1, 2]; var read = (item:Int) -> item + box.value; return switch (values[0]) { case 1: read(41); default: 0; }; }";
		for (end in 0...source.length + 1) {
			var prefix = source.substring(0, end), file = new SourceFile("Truncated.hx", prefix);
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
			default: throw "incomplete initializer did not produce an ErrorExpression";
		}
		var typeFile = new SourceFile("ErrorType.hx", "function main():Void { var incomplete:"),
			typeProgram = new Parser(new Lexer(typeFile).tokenize()).parseProgramRecovering().program;
		switch typeProgram.functions[0].statements[0] {
			case UninitializedDeclaration(_, ErrorType(_), _):
			default: throw "incomplete annotation did not produce an ErrorType";
		}
		var statementFile = new SourceFile("ErrorStatement.hx", "function main():Void { var = ; return; }"),
			statementProgram = new Parser(new Lexer(statementFile).tokenize()).parseProgramRecovering().program;
		switch statementProgram.functions[0].statements[0] {
			case ErrorStatement(_):
			default: throw "malformed statement did not produce an ErrorStatement";
		}
	}
}
