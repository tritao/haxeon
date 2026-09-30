import compiler.Source.SourceFile;
import compiler.Source.SourceSpan;
import compiler.syntax.Ast.AstFunction;
import compiler.syntax.Ast.AstStatement;
import compiler.syntax.Lexer;
import compiler.syntax.Parser;
import compiler.types.analysis.AssignedDeclarations;
import compiler.types.analysis.BindingWalker;
import compiler.types.analysis.LexicalStorageAnalysis;
import compiler.types.analysis.MapEscapeAnalysis;

/**
 * Analyses that read source before typing tell declarations apart by scope: the same name declared in two blocks, or
 * shadowed by a loop, catch, lambda or pattern variable, is a different variable each time.
 */
class BindingAnalysisMain {
	static function main():Void {
		// Cells: a local needs one when a lambda captures it and it is written.
		var fn = parse("function main():Void {
			var counter = 0;
			var untouched = 1;
			var read = function():Int return counter + untouched;
			var bump = function():Void { for (i in [1, 2]) { counter++; } };
		}");
		var storage = LexicalStorageAnalysis.analyze(fn.statements, fn.arguments);
		expect(storage.mutableCaptures.exists(declaration(fn, "counter", 0)),
			"a captured, written local needs a cell, even written in a loop inside the lambda");
		expect(!storage.mutableCaptures.exists(declaration(fn, "untouched", 0)), "a captured local that is never written does not");

		// Sibling declarations of one name are separate variables.
		fn = parse("function main():Void {
			var flag = true;
			if (flag) { var x = 0; var f = function():Void { x++; }; } else { var x = 1; var g = function():Int return x; }
		}");
		storage = LexicalStorageAnalysis.analyze(fn.statements, fn.arguments);
		expect(storage.mutableCaptures.exists(declaration(fn, "x", 0)), "the first x is captured and written");
		expect(!storage.mutableCaptures.exists(declaration(fn, "x", 1)), "the second x, in a sibling block, is only read by its lambda");

		// A lambda parameter of the same name shadows the local.
		fn = parse("function main():Void {
			var total = 0;
			total = 1;
			var f = function(total:Int):Int { total = total + 1; return total; };
		}");
		storage = LexicalStorageAnalysis.analyze(fn.statements, fn.arguments);
		expect(!storage.mutableCaptures.exists(declaration(fn, "total", 0)), "a lambda's own parameter is not a capture of the outer local");

		// Exception edges: written inside a try, declared outside it.
		fn = parse("function main():Void {
			var seen = 0;
			var later = 0;
			try { seen = 1; var inside = 2; inside = 3; } catch (e:Dynamic) { later = 1; }
		}");
		storage = LexicalStorageAnalysis.analyze(fn.statements, fn.arguments);
		expect(storage.exceptionCells.exists(declaration(fn, "seen", 0)), "a local written in a try needs a cell for the exception edge");
		expect(!storage.exceptionCells.exists(declaration(fn, "inside", 0)), "one declared inside the try does not");
		expect(!storage.exceptionCells.exists(declaration(fn, "later", 0)), "nor one written only in the handler");

		// A local function that calls itself lives in a cell.
		fn = parse("function main():Int {
			function fact(n:Int):Int { return n <= 1 ? 1 : n * fact(n - 1); }
			return fact(5);
		}");
		storage = LexicalStorageAnalysis.analyze(fn.statements, fn.arguments);
		expect(storage.mutableCaptures.exists(declaration(fn, "fact", 0)), "a recursive local function needs a cell");

		// Private maps: per declaration, not per name.
		fn = parse("function main():Void {
			var flag = true;
			if (flag) { var parts:Map<String, Int> = new Map(); parts.set(\"a\", 1); } else { var parts:Map<String, Int> = new Map(); leak(parts); }
			for (parts in [1, 2]) { trace(parts); }
		}");
		var privacy = MapEscapeAnalysis.analyze(fn.arguments, fn.statements);
		expect(privacy.isPrivate(declaration(fn, "parts", 0)), "a map only used through its operations is private");
		expect(!privacy.isPrivate(declaration(fn, "parts", 1)), "a same-named map in a sibling block that escapes is not");

		fn = parse("function main():Void {
			var m:Map<String, Int> = new Map();
			var f = function(m:Int):Int return m;
			try { m.set(\"a\", 1); } catch (m:Dynamic) { trace(m); }
			switch (1) { case m: trace(m); default: }
		}");
		privacy = MapEscapeAnalysis.analyze(fn.arguments, fn.statements);
		expect(privacy.isPrivate(declaration(fn, "m", 0)), "lambda, catch and pattern variables named m do not touch the map");

		fn = parse("function main():Void {
			var m:Map<String, Int> = new Map();
			var f = function():Void { m.remove(\"a\"); };
			var g:Map<String, Int> = new Map();
			var h = function():Int return g.size();
			var e:Map<String, Int> = [];
		}");
		privacy = MapEscapeAnalysis.analyze(fn.arguments, fn.statements);
		expect(!privacy.isPrivate(declaration(fn, "m", 0)), "a lambda that removes entries makes the map reachable");
		expect(privacy.isPrivate(declaration(fn, "g", 0)), "a lambda that only reads does not");
		expect(privacy.isPrivate(declaration(fn, "e", 0)), "an empty literal typed as a map is a map");

		// Assigned declarations: a write counts for the variable it resolves to, whichever name it shares.
		fn = parse("function main():Void {
			var x = 1;
			var y = 1;
			var box = {n: 0};
			if (true) { var x = 2; x = 3; }
			var f = function():Void { y++; box.n = 4; };
		}");
		var assigned = AssignedDeclarations.ofFunction(fn.arguments, fn.statements).declarations;
		expect(!assigned.exists(declaration(fn, "x", 0)), "writing an inner x does not write the outer one");
		expect(assigned.exists(declaration(fn, "x", 1)), "but it writes the inner one");
		expect(assigned.exists(declaration(fn, "y", 0)), "an increment inside a lambda writes the captured local");
		expect(!assigned.exists(declaration(fn, "box", 0)), "assigning a field of a local does not write the local");

		Sys.println("PASS: binding-aware analyses");
	}

	static function parse(source:String):AstFunction
		return new Parser(new Lexer(new SourceFile("Binding.hx", source)).tokenize()).parseProgram().functions[0];

	/** The identity of the `index`th declaration of `name` in source order. */
	static function declaration(fn:AstFunction, name:String, index:Int):String {
		var found:Array<SourceSpan> = [];
		collect(fn.statements, name, found);
		if (index >= found.length)
			throw 'no declaration ${index} of "$name"';
		return BindingWalker.key(name, found[index]);
	}

	static function collect(statements:Array<AstStatement>, name:String, found:Array<SourceSpan>):Void {
		for (statement in statements)
			switch statement {
				case VarDeclaration(declared, _, _, span) if (declared == name):
					found.push(span);
				case If(_, yes, no, _):
					collect(yes, name, found);
					collect(no, name, found);
				case Try(tryBranch, catches, _):
					collect(tryBranch, name, found);
					for (caught in catches)
						collect(caught.statements, name, found);
				default:
			}
	}

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}
}
