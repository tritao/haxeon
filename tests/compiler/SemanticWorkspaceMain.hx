import compiler.syntax.Lexer;
import compiler.syntax.Parser;
import compiler.Source.SourceFile;
import compiler.modules.ModuleState;
import compiler.semantic.SemanticWorkspace;
import compiler.semantic.SemanticWorkspace.WorkspaceResolution;
import compiler.semantic.SemanticModel;
import compiler.types.Type.CompilerType;
import compiler.service.LanguageService;
import compiler.runtime.RuntimeType;

class SemanticWorkspaceMain {
	static function main():Void {
		expect(RuntimeType.mapName(TString, TNullable(TAbstract("Symbol", [], TString))) == "map_string_bytes",
			"nullable reference abstracts should use their representation's map ABI");
		var base = parsedState("demo.Base", "package demo; class Base { public function value():Int return 1; }");
		var child = parsedState("demo.Child", "package demo; import demo.Base; class Child extends Base {}");
		child.dependencies = ["demo.Base"];
		var modules:Map<String, ModuleState> = [];
		modules.set(base.name, base);
		modules.set(child.name, child);
		var workspace = new SemanticWorkspace(modules);
		var resolvedBase = workspace.resolveTypeSymbolId("Base");
		expect(resolvedBase != null
			&& workspace.resolveTypeSymbolId("Base") == resolvedBase, "type resolution should be stable when cached");
		expect(workspace.resolveTypeSymbolId("demo.Base") == resolvedBase, "qualified type resolution should share the indexed symbol");
		expect(workspace.resolveSymbolId("Base") == resolvedBase && workspace.resolveSymbolId("demo.Base") == resolvedBase,
			"general symbol resolution should support bare and qualified names");
		workspace.invalidateResolutionCache();
		expect(workspace.resolveTypeSymbolId("Base") == resolvedBase, "invalidating resolution caches should preserve results");

		var global = workspace.global(child, "Base");
		expect(global != null && global.state == base && global.key == "class:Base", "imports should resolve through the workspace");
		var inherited = workspace.member(TInstance(Class, "demo.Child", []), "value");
		expect(inherited != null && inherited.state == base && inherited.key == "class:Base:method:value",
			"qualified classes should resolve inherited members across modules");
		var inheritedSymbol = workspace.memberSymbolId(TInstance(Class, "demo.Child", []), "value");
		expect(inheritedSymbol != null && workspace.resolveSymbolId("demo.Child.value") == inheritedSymbol,
			"qualified inherited member names should resolve to their compiler identity");

		var contract = parsedState("demo.Contract", "package demo; interface Contract { function required():Int; }");
		var implementer = parsedState("demo.Implementer", "package demo; import demo.Contract; class Implementer implements Contract {}");
		modules.set(contract.name, contract);
		modules.set(implementer.name, implementer);
		var interfaceInherited = new SemanticWorkspace(modules).member(TInstance(Class, "demo.Implementer", []), "required");
		expect(interfaceInherited != null && interfaceInherited.state == contract && interfaceInherited.key == "interface:Contract:method:required",
			"classes should resolve members supplied by implemented interfaces");

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
		expect(service.definition("Query.hx", query.source.text.indexOf("Base") + 1) == null, "editor queries should not guess an unbound ambiguous symbol");

		Sys.println("PASS: cross-module semantic workspace");
	}

	static function parsedState(name:String, text:String):ModuleState {
		var source = new SourceFile(name.split(".").join("/") + ".hx", text);
		var state = new ModuleState(name, source);
		state.tokens = new Lexer(source).tokenize();
		state.ast = new Parser(state.tokens).parseProgram();
		state.semanticModel = new SemanticModel(state.parsedAst(), source, state.revision, state.tokens);
		state.semanticModel.freeze();
		state.publishExactSnapshot();
		return state;
	}

	static function publish(state:ModuleState):Void {
		state.captureLastGoodSnapshot();
	}

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}
}
