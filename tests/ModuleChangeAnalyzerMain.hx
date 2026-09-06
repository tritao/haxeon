import compiler.Lexer;
import compiler.Parser;
import compiler.Source.SourceFile;
import compiler.modules.ModuleChangeAnalyzer;
import compiler.modules.ModuleCanonicalizer;
import compiler.modules.ModuleState;
import compiler.types.TypeRegistry;

class ModuleChangeAnalyzerMain {
	static function main():Void {
		var state = parsedState("Main", "function value():Int return 1; function main():Int return value();"),
			types = new TypeRegistry(),
			baseline = analyze(state, types, false);
		publish(state, baseline);

		parseInto(state, "function value():Int return 2; function main():Int return value();");
		var bodyEdit = analyze(state, types, true);
		expect(bodyEdit.bodyChanged.exists("Main.value"), "body edits should invalidate function bodies");
		expect(!bodyEdit.signatureChanged.exists("Main.value"), "body edits should preserve signatures");
		publish(state, bodyEdit);

		parseInto(state, "function value():Float return 2.0; function main():Int return 0;");
		var signatureEdit = analyze(state, types, true);
		expect(signatureEdit.signatureChanged.exists("Main.value"), "signature edits should invalidate callers");

		var aliasState = parsedState("Types", "typedef Count = Int;"),
			aliasTypes = new TypeRegistry(),
			aliasBaseline = analyze(aliasState, aliasTypes, false);
		publish(aliasState, aliasBaseline);
		parseInto(aliasState, "typedef Count = Float;");
		var aliasEdit = analyze(aliasState, aliasTypes, true);
		expect(aliasEdit.structuralChanged.exists("alias:Count"), "alias representation edits should be structural");

		Sys.println("PASS: module change classification");
	}

	static function analyze(state:ModuleState, types:TypeRegistry, compiledOnce:Bool):compiler.modules.ModuleChangeAnalyzer.ModuleChangeAnalysis {
		var aliases:Map<String, String> = [];
		ModuleCanonicalizer.addDeclaredTypeAliases(aliases, state.parsedAst(), state.parsedAst().packageName);
		return ModuleChangeAnalyzer.analyze(state, state.name, aliases, types, compiledOnce);
	}

	static function parsedState(name:String, source:String):ModuleState {
		var state = new ModuleState(name, new SourceFile(name + ".hx", source));
		parseInto(state, source);
		return state;
	}

	static function parseInto(state:ModuleState, source:String):Void {
		state.source = new SourceFile(state.name + ".hx", source);
		state.tokens = new Lexer(state.source).tokenize();
		state.ast = new Parser(state.tokens).parseProgram();
	}

	static function publish(state:ModuleState, analysis:compiler.modules.ModuleChangeAnalyzer.ModuleChangeAnalysis):Void {
		state.signatureFingerprints = analysis.signatureFingerprints;
		state.bodyFingerprints = analysis.bodyFingerprints;
		state.interfaceFingerprints = analysis.interfaceFingerprints;
		state.aliasFingerprints = analysis.aliasFingerprints;
		state.enumFingerprints = analysis.enumFingerprints;
		state.staticInitializerFingerprints = analysis.staticInitializerFingerprints;
		state.instanceInitializerFingerprints = analysis.instanceInitializerFingerprints;
	}

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}
}
