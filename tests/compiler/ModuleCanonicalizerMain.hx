import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstStatement;
import compiler.syntax.Ast.AstType;
import compiler.syntax.Lexer;
import compiler.syntax.Parser;
import compiler.Source.SourceFile;
import compiler.semantic.ModuleCanonicalizer;

class ModuleCanonicalizerMain {
	static function main():Void {
		var source = 'function helper(value:Alias):Alias { return value; } function run(value:Alias):Alias { return helper(value); }',
			program = new Parser(new Lexer(new SourceFile("demo/Main.hx", source)).tokenize()).parseProgram(),
			locals:Map<String, Bool> = ["helper" => true, "run" => true],
			aliases:Map<String, String> = ["Alias" => "demo.Value"],
			canonical = ModuleCanonicalizer.canonicalFunction(program.functions[1], "demo.Main", "demo.Main", locals, null, aliases);
		expect(canonical.name == "demo.Main.run", "function name should be module-qualified");
		expect(switch canonical.arguments[0].type {
			case NamedType("demo.Value"): true;
			default: false;
		}, "argument aliases should resolve to canonical types");
		expect(switch canonical.statements[0] {
			case Return(Call("demo.Main.helper", _, _), _): true;
			default: false;
		}, "local calls should resolve to canonical function names");

		var imported = ModuleCanonicalizer.canonicalExpression(Call("Util.work", [], canonical.span), "demo.Main", "demo.Main", locals, ["Util" => "lib.Util"]);
		expect(switch imported {
			case Call("lib.Util.work", _, _): true;
			default: false;
		}, "import aliases should preserve qualified member suffixes");

		// An assignment target is a dotted name, and an imported class in it is qualified like any other reference.
		function assigned(name:String, locals:Map<String, Bool>, aliases:Null<Map<String, String>>):String
			return switch ModuleCanonicalizer.canonicalStatement(Assignment(name, IntegerLiteral(1, canonical.span), canonical.span), "demo.Main",
				"demo.Main", locals, aliases) {
				case Assignment(target, _, _): target;
				default: "?";
			};
		var imports:Map<String, String> = ["Cache" => "lib.Cache"];
		expect(assigned("Cache.hits", locals, imports) == "lib.Cache.hits", "an imported class in an assignment target should be qualified");
		expect(assigned("hits", locals, imports) == "hits", "a bare assignment target is never an import");
		expect(assigned("owner.hits", locals, imports) == "owner.hits", "a receiver that is not an import is left alone");
		expect(assigned("Cache.hits", ["Cache" => true], imports) == "Cache.hits", "a name declared in the module shadows an import in an assignment target");
		expect(assigned("Cache.hits", locals, null) == "Cache.hits", "without imports an assignment target is unchanged");

		Sys.println("PASS: module syntax canonicalization");
	}

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}
}
