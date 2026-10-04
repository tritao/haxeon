import compiler.semantic.AliasTable;
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
			aliases = AliasTable.of(["Alias" => "demo.Value"]),
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

		var imported = ModuleCanonicalizer.canonicalExpression(Call("Util.work", [], canonical.span), "demo.Main", "demo.Main", locals,
			AliasTable.of(["Util" => "lib.Util"]));
		expect(switch imported {
			case Call("lib.Util.work", _, _): true;
			default: false;
		}, "import aliases should preserve qualified member suffixes");

		// An assignment target is a dotted name, and an imported class in it is qualified like any other reference.
		function assigned(name:String, locals:Map<String, Bool>, aliases:Null<AliasTable>):String
			return switch ModuleCanonicalizer.canonicalStatement(Assignment(name, IntegerLiteral(1, canonical.span), canonical.span), "demo.Main",
				"demo.Main", locals, aliases) {
				case Assignment(target, _, _): target;
				default: "?";
			};
		var imports = AliasTable.of(["Cache" => "lib.Cache"]);
		expect(assigned("Cache.hits", locals, imports) == "lib.Cache.hits", "an imported class in an assignment target should be qualified");
		expect(assigned("hits", locals, imports) == "hits", "a bare assignment target is never an import");
		expect(assigned("owner.hits", locals, imports) == "owner.hits", "a receiver that is not an import is left alone");
		expect(assigned("Cache.hits", ["Cache" => true], imports) == "Cache.hits", "a name declared in the module shadows an import in an assignment target");
		expect(assigned("Cache.hits", locals, null) == "Cache.hits", "without imports an assignment target is unchanged");

		// A table layers shared maps under the names it sets itself, in the order they were attached, without changing them.
		var explicit:Map<String, String> = ["Own" => "explicit.Own"],
			shared:Map<String, String> = ["Own" => "shared.Own", "Wide" => "shared.Wide"],
			later:Map<String, String> = ["Wide" => "later.Wide", "Late" => "later.Late"];
		var table = AliasTable.of(explicit);
		table.attach(shared);
		expect(!table.exists("Late"), "a layer that is not attached yet is not consulted");
		table.attach(later);
		expect(table.get("Own") == "explicit.Own", "an earlier layer outranks a later one");
		expect(table.get("Wide") == "shared.Wide" && table.get("Late") == "later.Late", "layers resolve in the order they were attached");
		table.set("Wide", "local.Wide");
		expect(table.get("Wide") == "local.Wide" && shared.get("Wide") == "shared.Wide",
			"a name set in the table outranks the layers and leaves them unchanged");
		var nested = table.child();
		nested.set("T", "T");
		nested.remove("Own");
		expect(nested.get("T") == "T" && !table.exists("T"), "a nested table keeps its own names");
		expect(!nested.exists("Own") && table.get("Own") == "explicit.Own", "a removed name is hidden in the nested table only");
		nested.set("Own", "nested.Own");
		expect(nested.get("Own") == "nested.Own", "a removed name can be set again");
		expect(nested.get("Wide") == "local.Wide", "a nested table sees its parent's names");

		Sys.println("PASS: module syntax canonicalization");
	}

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}
}
