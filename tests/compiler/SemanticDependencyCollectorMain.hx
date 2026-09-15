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

		var genericSource = 'package demo; class Box<T> { public var value:T; public function convert<U>(value:U):T return this.value; } function identity<V>(value:V):V return value;',
			genericFile = new SourceFile("demo/Box.hx", genericSource),
			generic = new ModuleState("demo.Box", genericFile);
		generic.ast = new Parser(new Lexer(genericFile).tokenize()).parseProgram();
		var genericDependencies = SemanticDependencyCollector.collectSemanticDependencies(generic, "demo.Box", []);
		expect(countTargets(genericDependencies, "demo.T") == 0
			&& countTargets(genericDependencies, "demo.U") == 0
			&& countTargets(genericDependencies, "demo.V") == 0,
			"generic parameters must not become module dependencies");

		Sys.println("PASS: semantic dependency collection");
	}

	static function count(dependencies:Array<compiler.modules.ModuleState.SemanticDependency>, kind:SemanticDependencyKind, target:String):Int {
		var result = 0;
		for (dependency in dependencies)
			if (dependency.kind == kind && dependency.target == target)
				result++;
		return result;
	}

	static function countTargets(dependencies:Map<String, Array<compiler.modules.ModuleState.SemanticDependency>>, target:String):Int {
		var result = 0;
		for (entries in dependencies)
			for (dependency in entries)
				if (dependency.target == target)
					result++;
		return result;
	}

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}
}
