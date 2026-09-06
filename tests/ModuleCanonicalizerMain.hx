import compiler.Ast.AstExpression;
import compiler.Ast.AstStatement;
import compiler.Ast.AstType;
import compiler.Lexer;
import compiler.Parser;
import compiler.Source.SourceFile;
import compiler.modules.ModuleCanonicalizer;

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

		Sys.println("PASS: module syntax canonicalization");
	}

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}
}
