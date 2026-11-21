import compiler.core.Source.SourceFile;
import compiler.modules.ModuleState;
import compiler.semantic.AliasTable;
import compiler.semantic.ModuleCanonicalizer;
import compiler.semantic.ModuleChangeAnalyzer;
import compiler.syntax.Lexer;
import compiler.syntax.Parser;
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
		expect(analyze(aliasState, aliasTypes, true).structuralChanged.exists("alias:Count"),
			"an analysis must not publish its fingerprints: analyzing the same edit again finds the same change");

		var enumState = parsedState("Color", "enum Color { Red; Green; }"),
			enumTypes = new TypeRegistry();
		publish(enumState, analyze(enumState, enumTypes, false));
		parseInto(enumState, "enum Color { Red; Green(shade:Int); }");
		var enumEdit = analyze(enumState, enumTypes, true);
		expect(enumEdit.structuralChanged.exists("enum:Color"), "enum case edits should be structural");
		publish(enumState, enumEdit);
		parseInto(enumState, "enum Color { Red; Green(shade:Int); } // a comment");
		expect(!analyze(enumState, enumTypes, true).structuralChanged.exists("enum:Color"),
			"an enum whose shape is the published one is unchanged");

		var abstractState = parsedState("Meters", "abstract Meters(Int) from Int {}"),
			abstractTypes = new TypeRegistry();
		publish(abstractState, analyze(abstractState, abstractTypes, false));
		parseInto(abstractState, "abstract Meters(Float) from Int {}");
		var abstractEdit = analyze(abstractState, abstractTypes, true);
		expect(abstractEdit.structuralChanged.exists("abstract:Meters"),
			"abstract representation edits should be structural");
		publish(abstractState, abstractEdit);
		parseInto(abstractState, "abstract Meters(Float) {}");
		var conversionEdit = analyze(abstractState, abstractTypes, true);
		expect(conversionEdit.structuralChanged.exists("abstract:Meters"),
			"abstract conversion edits should be structural");
		publish(abstractState, conversionEdit);
		parseInto(abstractState, "abstract Meters(Float) {}\n");
		expect(!analyze(abstractState, abstractTypes, true).structuralChanged.exists("abstract:Meters"),
			"an abstract whose shape is the published one is unchanged");

		var wireState = parsedState("Wire", "@:wire class Wire { @:id(1) public var value:Int; }");
		var wireTypes = new TypeRegistry();
		publish(wireState, analyze(wireState, wireTypes, false));
		parseInto(wireState, "@:wire class Wire { @:id(2) public var value:Int; }");
		var wireEdit = analyze(wireState, wireTypes, true);
		expect(wireEdit.structuralChanged.exists("Wire"), "wire field ID edits should be structural");

		Sys.println("PASS: module change classification");
	}

	static function analyze(state:ModuleState, types:TypeRegistry,
			compiledOnce:Bool):compiler.semantic.ModuleChangeAnalyzer.ModuleChangeAnalysis {
		var aliases = new AliasTable();
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
		state.tokens = new Lexer(state.source).tokenizeTable();
		state.ast = new Parser(state.tokens).parseProgram();
	}

	static function publish(state:ModuleState,
			analysis:compiler.semantic.ModuleChangeAnalyzer.ModuleChangeAnalysis):Void
		ModuleChangeAnalyzer.publish(state, analysis);

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}
}
