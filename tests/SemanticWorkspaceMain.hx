import compiler.Lexer;
import compiler.Parser;
import compiler.Source.SourceFile;
import compiler.modules.ModuleState;
import compiler.modules.SemanticWorkspace;
import compiler.types.SemanticModel;
import compiler.types.Type.CompilerType;

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
		var inherited = workspace.member(TClass("demo.Child"), "value");
		expect(inherited != null && inherited.state == base && inherited.key == "class:Base:method:value",
			"qualified classes should resolve inherited members across modules");

		publish(base);
		base.update(new SourceFile("demo/Base.hx", "class Base {"));
		var stale = new SemanticWorkspace(modules).member(TClass("demo.Base"), "value");
		expect(stale != null && stale.state == base, "failed edits should retain last-good workspace lookup");

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
