import compiler.syntax.Lexer;
import compiler.syntax.Parser;
import compiler.Source.SourceFile;
import compiler.types.DeclarationIndex.DeclarationKind;
import compiler.types.SemanticProgram;
import compiler.types.Typer;

class SemanticProgramMain {
	static function main():Void {
		var source = new SourceFile("Main.hx", "function identity(value:Int):Int return value; function main():Int return identity(42);");
		var parsed = new Parser(new Lexer(source).tokenize()).parseProgram();
		var semantic = SemanticProgram.analyze(parsed);

		expect(semantic.program.functions[0].arguments[0].type == IntType, "semantic analysis should retain the program paired with its index");
		expect(semantic.declarations.symbol(DeclarationKind.Function, "identity") != null, "semantic analysis should own validated declarations");
		var selected:Map<String, Bool> = ["identity" => true, "main" => true];
		var typed = Typer.typeAnalyzed(semantic, selected);
		expect(typed.functions.length == 2, "Typer should consume the analyzed semantic program");

		Sys.println("PASS: validated semantic program feeds Typer");
	}

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}
}
