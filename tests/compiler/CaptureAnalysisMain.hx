import compiler.syntax.Lexer;
import compiler.syntax.Parser;
import compiler.Source.SourceFile;
import compiler.types.analysis.BindingStoragePlan;
import compiler.types.analysis.LexicalStorageAnalysis;
import compiler.types.Type.CompilerType;
import compiler.types.TypedAst.CellStorageKind;

class CaptureAnalysisMain {
	static function main():Void {
		var lexicalShadowed = analyzeLexically('function main():Int { var value = 1; var local = () -> { var value = 2; value = value + 1; return value; }; return local(); }');
		expect(count(lexicalShadowed.mutableCaptures) == 0, "lambda-local writes must not request storage in the enclosing body");

		var lexicalMutable = analyzeLexically('function main():Int { var value = 0; var increment = () -> { value = value + 1; return value; }; return increment(); }');
		expect(count(lexicalMutable.mutableCaptures) == 1, "the resolver must identify exactly one mutable captured declaration");
		expect(firstKey(lexicalMutable.mutableCaptures).indexOf("value@") == 0, "storage identities must include the declaration site");

		var receiver = analyzeLexically('function main():Int { var box = new Box(1); box = new Box(2); var read = () -> box.answer(); return read(); }');
		expect(count(receiver.mutableCaptures) == 1, "method-only captured receivers must use cells from their declaration");
		var callee = analyzeLexically('function main():Int { var f = () -> 1; f = () -> 2; var read = () -> f(); return read(); }');
		expect(count(callee.mutableCaptures) == 1, "call-only captured functions must use cells from their declaration");
		var immutable = analyzeLexically('function main():Int { var box = new Box(1); var read = () -> box.answer(); return read(); }');
		expect(count(immutable.mutableCaptures) == 0, "immutable receiver captures should remain direct values");

		var exception = analyzeLexically('function main():Int { var value = 0; try { value = 42; throw "stop"; } catch (error:Dynamic) { return value; } }');
		expect(count(exception.exceptionCells) == 1 && firstKey(exception.exceptionCells).indexOf("value@") == 0,
			"local crossing a throwing edge should require stable storage");

		var loopShadowing = analyzeLexically('function main():Int { try { for (name => state in [1 => 2]) { state = state + 1; trace(name); } } catch (error:Dynamic) { for (name => state in [3 => 4]) trace(name + state); } return 0; }');
		expect(count(loopShadowing.exceptionCells) == 0, "separate loop keys and values must not alias across an exception edge");

		var plan = new BindingStoragePlan();
		plan.request("value@1", "$cell:test:value", ExceptionEdge);
		plan.request("value@1", "$cell:test:value", MutableCapture);
		plan.request("value@2", "$cell:test:value", ExceptionEdge);
		var outer = plan.bind("value@1", "$l0:value", CompilerType.TInt),
			inner = plan.bind("value@2", "$l1:value", CompilerType.TInt);
		expect(outer != inner, "shadowed bindings must receive distinct cells");
		expect(plan.kinds.get("$l0:value") == MutableCapture, "mutable capture storage must take precedence over exception storage");
		expect(!plan.cells.exists("value"), "source names must not escape into resolved cell maps");

		Sys.println("PASS: capture and exception-edge storage analysis");
	}

	static function analyzeLexically(source:String):compiler.types.analysis.LexicalStorageAnalysis.LexicalStorageRequirements {
		var program = new Parser(new Lexer(new SourceFile("capture-analysis.hx", source)).tokenize()).parseProgram();
		var fn = program.functions[0];
		return LexicalStorageAnalysis.analyze(fn.statements, fn.arguments);
	}

	static function count(values:Map<String, Bool>):Int {
		var result = 0;
		for (_ in values)
			result++;
		return result;
	}

	static function firstKey(values:Map<String, Bool>):String {
		for (key in values.keys())
			return key;
		return "";
	}

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}
}
