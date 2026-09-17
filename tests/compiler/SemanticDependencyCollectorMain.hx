import compiler.syntax.Lexer;
import compiler.syntax.Parser;
import compiler.Source.SourceFile;
import compiler.modules.ModuleState;
import compiler.modules.ModuleState.SemanticDependencyKind;
import compiler.semantic.SemanticDependencyCollector;
import compiler.semantic.DependencyScanner;
import compiler.Compiler;

class SemanticDependencyCollectorMain {
	static function main():Void {
		var source = 'function helper(value:Alias):Alias { return value; } function run(value:Alias):Alias { helper(value); return helper(value); }',
			file = new SourceFile("demo/Main.hx", source),
			state = new ModuleState("demo.Main", file);
		state.ast = new Parser(new Lexer(file).tokenize()).parseProgram();
		var dependencies = SemanticDependencyCollector.collectSemanticDependencies(state, "demo.Main", ["Alias" => "demo.Value"]),
			run = dependencies.get("demo.Main.run");
		expect(run != null, "run should have recorded semantic dependencies");
		expect(count(run, Signature, "demo.Value") == 1, "identical signature dependencies should be deduplicated");
		expect(count(run, Body, "demo.Main.helper") == 1, "repeated calls should produce one body dependency");

		var entrySource = 'function main():Int { return helper(); } function helper():Int { return 42; }',
			entryFile = new SourceFile("Main.hx", entrySource),
			entry = new ModuleState("Main", entryFile);
		entry.ast = new Parser(new Lexer(entryFile).tokenize()).parseProgram();
		var entryDependencies = SemanticDependencyCollector.collectSemanticDependencies(entry, "Main", []);
		expect(count(entryDependencies.get("main"), Body, "Main.helper") == 1, "entry-point ownership should remain canonical");

		var scannerSource = 'function main():Void { var value:Imported; var values = new Array<Imported>(0); var map = new Map<Imported, Imported>(); var casted = (value:Imported); sizeof<Imported>(); var lambda = (item:Imported) -> item; }',
			scannerFile = new SourceFile("deps/Main.hx", scannerSource),
			scannerProgram = new Parser(new Lexer(scannerFile).tokenize()).parseProgram(),
			scanned:Map<String, Bool> = [];
		for (statement in scannerProgram.functions[0].statements)
			DependencyScanner.scanStatement(statement, scanned);
		expect(scanned.exists("Imported"), "dependency scanning should retain local and nested type references");

		var moduleCompiler = new Compiler();
		moduleCompiler.update("deps/Imported.hx", "package deps; class Imported<T> {} function main():Void return;");
		moduleCompiler.update("deps/Consumer.hx", "package deps; function main():Void { var value:Imported<Int>; }");
		moduleCompiler.compile("deps.Consumer");
		expect(moduleCompiler.modules.get("deps.Consumer").dependencies.indexOf("deps.Imported") >= 0,
			"module analysis should retain same-package dependencies from local generic annotations");

		Sys.println("PASS: semantic dependency collection");
	}

	static function count(dependencies:Array<compiler.modules.ModuleState.SemanticDependency>, kind:SemanticDependencyKind, target:String):Int {
		var result = 0;
		for (dependency in dependencies)
			if (dependency.kind == kind && dependency.target == target)
				result++;
		return result;
	}

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}
}
