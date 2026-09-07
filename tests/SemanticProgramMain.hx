import compiler.syntax.Lexer;
import compiler.syntax.Parser;
import compiler.Source.SourceFile;
import compiler.types.DeclarationIndex.DeclarationKind;
import compiler.semantic.SemanticProgram;
import compiler.types.Typer;
import compiler.semantic.DeclarationLifecycle;
import compiler.semantic.DeclarationLifecycle.DeclarationStage;

class SemanticProgramMain {
	static function main():Void {
		var source = new SourceFile("Main.hx", "function identity(value:Int):Int return value; function main():Int return identity(42);");
		var parsed = new Parser(new Lexer(source).tokenize()).parseProgram();
		var semantic = SemanticProgram.analyze(parsed);
		var identity = semantic.declarations.symbol(DeclarationKind.Function, "identity").id;
		expect(semantic.lifecycle.stage(identity) == SignatureTyped, "analysis should stop at typed signatures before Typer runs");

		expect(semantic.program.functions[0].arguments[0].type == IntType, "semantic analysis should retain the program paired with its index");
		expect(semantic.declarations.symbol(DeclarationKind.Function, "identity") != null, "semantic analysis should own validated declarations");
		var selected:Map<String, Bool> = ["identity" => true, "main" => true];
		var typed = Typer.typeAnalyzed(semantic, selected);
		expect(typed.functions.length == 2, "Typer should consume the analyzed semantic program");
		expect(semantic.lifecycle.stage(identity) == Finalized, "successful typing should finalize declarations");

		var declarationsOnly = SemanticProgram.analyzeThrough(parsed, Declared);
		expect(declarationsOnly.lifecycle.stage(identity) == Declared, "declaration-only analysis advanced too far");
		try {
			Typer.typeAnalyzed(declarationsOnly, selected);
			throw "Typer accepted declarations without signatures";
		} catch (error:String) {
			expect(error.indexOf("signature-typed is required") >= 0, "premature body typing produced the wrong lifecycle error");
		}
		var shapes = SemanticProgram.analyzeThrough(parsed, ShapeConnected);
		expect(shapes.lifecycle.stage(identity) == ShapeConnected, "shape-only analysis advanced too far");

		var machine = new DeclarationLifecycle(declarationsOnly.declarations);
		try {
			machine.advanceAll(BodyTyped);
			throw "declaration lifecycle allowed a skipped stage";
		} catch (error:String) {
			expect(error.indexOf("cannot advance") >= 0, "skipped lifecycle stage produced the wrong error");
		}

		Sys.println("PASS: validated semantic program feeds Typer");
	}

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}
}
