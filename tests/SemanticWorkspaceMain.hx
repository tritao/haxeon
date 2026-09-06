import compiler.Lexer;
import compiler.Parser;
import compiler.Source.SourceFile;
import compiler.modules.ModuleState;
import compiler.semantic.SemanticWorkspace;
import compiler.semantic.SemanticWorkspace.WorkspaceResolution;
import compiler.types.SemanticModel;
import compiler.types.Type.CompilerType;
import compiler.service.LanguageService;
import compiler.Diagnostic.CompileError;

class SemanticWorkspaceMain {
	static function main():Void {
		var base = parsedState("demo.Base", "package demo; class Base { public function value():Int return 1; }");
		var child = parsedState("demo.Child", "package demo; import demo.Base; class Child extends Base {}");
		child.dependencies = ["demo.Base"];
		var modules:Map<String, ModuleState> = [];
		modules.set(base.name, base);
		modules.set(child.name, child);
		var workspace = new SemanticWorkspace(modules);

		var global = workspace.global(child, "Base");
		expect(global != null && global.state == base && global.key == "class:Base", "imports should resolve through the workspace");
		var inherited = workspace.member(TInstance(Class, "demo.Child", []), "value");
		expect(inherited != null && inherited.state == base && inherited.key == "class:Base:method:value",
			"qualified classes should resolve inherited members across modules");

		publish(base);
		base.update(new SourceFile("demo/Base.hx", "class Base {"));
		var stale = new SemanticWorkspace(modules).member(TInstance(Class, "demo.Base", []), "value");
		expect(stale != null && stale.state == base, "failed edits should retain last-good workspace lookup");

		var other = parsedState("other.Base", "package other; function Base():Int return 2;");
		modules.set(other.name, other);
		child.dependencies.push(other.name);
		switch new SemanticWorkspace(modules).globalResolution(child, "Base") {
			case Ambiguous(declarations):
				expect(declarations.length == 2, "ambiguity should retain every candidate");
			case _:
				throw "workspace should report ambiguous imported declarations";
		}

		var service = new LanguageService(),
			query = parsedState("Query", "function main():Int return Base;");
		query.dependencies = [base.name, other.name];
		service.compiler.modules.set(query.name, query);
		service.compiler.modules.set(base.name, base);
		service.compiler.modules.set(other.name, other);
		try {
			service.definition("Query.hx", query.source.text.indexOf("Base") + 1);
			throw "ambiguous editor lookup should produce a diagnostic";
		} catch (error:CompileError) {
			expect(error.diagnostic.code == "E2001", "ambiguous lookup should use its stable diagnostic code");
		}

		Sys.println("PASS: cross-module semantic workspace");
	}

	static function parsedState(name:String, text:String):ModuleState {
		var source = new SourceFile(name.split(".").join("/") + ".hx", text);
		var state = new ModuleState(name, source);
		state.tokens = new Lexer(source).tokenize();
		state.ast = new Parser(state.tokens).parseProgram();
		state.semanticModel = new SemanticModel(state.parsedAst(), source, state.revision);
		return state;
	}

	static function publish(state:ModuleState):Void {
		state.lastGoodTokens = state.tokens;
		state.lastGoodAst = state.ast;
		state.lastGoodSemanticModel = state.semanticModel;
		state.lastGoodSource = state.source;
		state.lastGoodRevision = state.revision;
	}

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}
}
