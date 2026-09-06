import compiler.Lexer;
import compiler.Parser;
import compiler.Source.SourceFile;
import compiler.types.analysis.CaptureAnalysis;

class CaptureAnalysisMain {
	static function main():Void {
		var mutable = analyze('function main():Int { var value = 0; var increment = () -> { value = value + 1; return value; }; return increment(); }');
		expect(mutable.mutableCaptures.exists("value"), "mutable outer local should require capture storage");

		var shadowed = analyze('function main():Int { var value = 1; var local = () -> { var value = 2; value = value + 1; return value; }; return local(); }');
		expect(!shadowed.mutableCaptures.exists("value"), "shadowed lambda local should not capture the outer binding");

		var exception = analyze('function main():Int { var value = 0; try { value = 42; throw "stop"; } catch (error:Dynamic) { return value; } }');
		expect(exception.exceptionCells.exists("value"), "local crossing a throwing edge should require stable storage");

		Sys.println("PASS: capture and exception-edge storage analysis");
	}

	static function analyze(source:String):compiler.types.analysis.CaptureAnalysis.BodyStorageAnalysis {
		var program = new Parser(new Lexer(new SourceFile("capture-analysis.hx", source)).tokenize()).parseProgram();
		return CaptureAnalysis.analyze(program.functions[0].statements, []);
	}

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}
}
