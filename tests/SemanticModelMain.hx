import compiler.syntax.Lexer;
import compiler.syntax.Parser;
import compiler.Source.SourceFile;
import compiler.types.DeclarationIndex.DeclarationKind;
import compiler.types.SemanticModel;

class SemanticModelMain {
	static function main():Void {
		var source = new SourceFile("Types.hx", "package demo; typedef Count = Missing; class Counter {} function make():Count return 1;");
		var program = new Parser(new Lexer(source).tokenize()).parseProgram();
		var model = new SemanticModel(program, source, 7);

		expect(model.revision == 7, "semantic model should retain its source revision");
		expect(model.program == program, "semantic model should retain its parsed program");
		expect(model.declarations.symbol(DeclarationKind.Alias, "Count") != null, "semantic model should index aliases");
		expect(model.declarations.symbol(DeclarationKind.Class, "Counter") != null, "semantic model should index classes");
		expect(model.declarations.symbol(DeclarationKind.Function, "make") != null, "semantic model should index functions");

		var emptySource = new SourceFile("Empty.hx", "package demo;");
		var emptyProgram = new Parser(new Lexer(emptySource).tokenize()).parseProgram();
		new SemanticModel(emptyProgram, emptySource, 1);

		Sys.println("PASS: revision-bound semantic model");
	}

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}
}
