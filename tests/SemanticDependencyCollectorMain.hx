import compiler.syntax.Lexer;
import compiler.syntax.Parser;
import compiler.Source.SourceFile;
import compiler.modules.ModuleState;
import compiler.modules.ModuleState.SemanticDependencyKind;
import compiler.semantic.SemanticDependencyCollector;

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
