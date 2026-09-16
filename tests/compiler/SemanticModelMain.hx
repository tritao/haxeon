import compiler.syntax.Lexer;
import compiler.syntax.Parser;
import compiler.Source.SourceFile;
import compiler.types.DeclarationIndex.DeclarationKind;
import compiler.semantic.SemanticModel;
import compiler.modules.AnalysisSnapshot;

class SemanticModelMain {
	static function main():Void {
		var source = new SourceFile("Types.hx", "package demo; typedef Count = Missing; class Counter {} function make():Count return 1;");
		var tokens = new Lexer(source).tokenize(),
			program = new Parser(tokens).parseProgram();
		var model = new SemanticModel(program, source, 7, tokens);
		model.freeze();
		var frozenIndex = model.index;
		model.freeze();
		expect(model.index == frozenIndex, "freezing a semantic model twice should preserve its query view");

		expect(model.revision == 7, "semantic model should retain its source revision");
		expect(model.program == program, "semantic model should retain its parsed program");
		expect(model.declarations.symbol(DeclarationKind.Alias, "Count") != null, "semantic model should index aliases");
		expect(model.declarations.symbol(DeclarationKind.Class, "Counter") != null, "semantic model should index classes");
		expect(model.declarations.symbol(DeclarationKind.Function, "make") != null, "semantic model should index functions");
		var make = model.index.symbolAt(source.text.indexOf("make"));
		expect(make != null
			&& make.name == "make"
			&& Std.string(make.id) == "Types:function:make", "semantic model should bind declaration positions");
		var exposedSymbols = model.index.symbols;
		exposedSymbols.remove(make.id);
		expect(model.index.symbolAt(source.text.indexOf("make")) != null,
			"semantic index query symbols must not expose mutable builder state");
		var makeLocations = model.index.locations(make.id),
			locationCount = makeLocations.length;
		makeLocations.pop();
		expect(model.index.locations(make.id).length == locationCount,
			"semantic index query locations must be detached from published state");
		var mutationRejected = false;
		try {
			model.indexTypeReferences(function(_name) return null);
		} catch (_:Dynamic) {
			mutationRejected = true;
		}
		expect(mutationRejected, "published semantic index builder accepted mutation");
		var metadataMutationRejected = false;
		try {
			model.recoveredSignatureProgram = program;
		} catch (_:Dynamic) {
			metadataMutationRejected = true;
		}
		expect(metadataMutationRejected, "published semantic model accepted recovery metadata mutation");

		var unfrozen = new SemanticModel(program, source, 7, tokens),
			unfrozenPublicationRejected = false;
		try {
			AnalysisSnapshot.exact(source, tokens, program, unfrozen, 7);
		} catch (_:Dynamic) {
			unfrozenPublicationRejected = true;
		}
		expect(unfrozenPublicationRejected, "analysis snapshot published an unfrozen semantic model");
		unfrozen.freeze();
		var revisionMismatch = new SemanticModel(program, source, 8, tokens);
		revisionMismatch.freeze();
		var mismatchRejected = false;
		try {
			AnalysisSnapshot.exact(source, tokens, program, revisionMismatch, 7);
		} catch (_:Dynamic) {
			mismatchRejected = true;
		}
		expect(mismatchRejected, "analysis snapshot accepted a mismatched semantic revision");

		var emptySource = new SourceFile("Empty.hx", "package demo;");
		var emptyTokens = new Lexer(emptySource).tokenize(),
			emptyProgram = new Parser(emptyTokens).parseProgram();
		var emptyModel = new SemanticModel(emptyProgram, emptySource, 1, emptyTokens);
		emptyModel.freeze();

		Sys.println("PASS: revision-bound semantic model");
	}

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}
}
