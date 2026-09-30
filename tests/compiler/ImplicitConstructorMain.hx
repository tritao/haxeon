import compiler.Compiler;
import compiler.Diagnostic.CompileError;
import compiler.Frontend;
import compiler.ir.IrInterpreter;
import compiler.semantic.Invalidation.InvalidatedArtifact;
import compiler.semantic.Invalidation.InvalidationKind;
import compiler.syntax.Ast.AstClass;
import compiler.syntax.Ast.AstType;
import compiler.syntax.Ast.AstFunction;
import compiler.semantic.ImplicitConstructors;

/**
 * A class that declares no constructor has its base class's, arguments included. Compilation gives it one that calls
 * `super`, so it is typed, tracked and invalidated like a written one.
 */
class ImplicitConstructorMain {
	static function main():Void {
		// The forwarding constructor takes the base's arguments, with the base's type parameters replaced.
		var classes = [
			declared("Base", null, ["Int", "String"], []),
			declared("Middle", "Base", [], []),
			declared("Leaf", "Middle", [], []),
			declared("Box", null, ["T"], ["T"]),
			declared("IntBox", "Box<Int>", [], []),
			declared("Plain", null, [], [])
		];
		var added = ImplicitConstructors.add(classes);
		expect([for (entry in added) entry.owner].join(",") == "Middle,Leaf,IntBox",
			"constructors are added to derived classes without one, found: " + [for (entry in added) entry.owner].join(","));
		expect(argumentTypes(classes, "Middle") == "Int,String", "Middle takes the arguments of Base");
		expect(argumentTypes(classes, "Leaf") == "Int,String", "and Leaf the ones Middle forwards");
		expect(argumentTypes(classes, "IntBox") == "Int", "a generic base's parameter is replaced by what the class extends it with");
		expect(argumentTypes(classes, "Plain") == "", "a class with no base gets nothing");

		// A base constructor is not needed for the chain to be constructed: initializers count.
		var withInitializer = [declared("A", null, [], [], true), declared("B", "A", [], [])];
		expect(ImplicitConstructors.add(withInitializer).length == 1, "a base with only field initializers still has a constructor to run");

		// Editing the base's constructor retypes the derived one.
		var compiler = new Compiler();
		compiler.update("Base.hx", "class Base { public var n:Int; public function new(n:Int) { this.n = n; } }");
		compiler.update("Derived.hx", "class Derived extends Base {}");
		compiler.update("Main.hx", "function main():Int { var d = new Derived(40); return d.n + 2; }");
		compiler.compile("Main");
		compiler.update("Base.hx", "class Base { public var n:Int; public function new(n:Int, extra:Int = 0) { this.n = n + extra; } }");
		var changed = compiler.compile("Main");
		var retyped = false;
		for (entry in changed.invalidations)
			if (entry.artifact == "Derived.new")
				retyped = true;
		expect(retyped, "changing the base constructor must retype the derived one: " + changed.invalidations);
		compiler.update("Base.hx", "class Base { public var n:Int; public function new(n:String) { this.n = 1; } }");
		var incompatible = false;
		try {
			compiler.compile("Main");
		} catch (_:CompileError) {
			incompatible = true;
		}
		expect(incompatible, "a caller of the inherited constructor sees the new signature");

		Sys.println("PASS: implicit constructors");
	}

	static function declared(name:String, base:Null<String>, arguments:Array<String>, typeParameters:Array<String>, initializer:Bool = false):AstClass {
		var source = "class "
			+ name
			+ (typeParameters.length > 0 ? "<" + typeParameters.join(", ") + ">" : "")
			+ (base == null ? "" : " extends " + base)
			+ " {"
			+ (initializer ? " public var items:Array<Int> = [1];" : "")
			+ (arguments.length > 0 ? " public function new("
				+ [for (index in 0...arguments.length) "a" + index + ":" + arguments[index]].join(", ") + ") {}" : "")
			+ " }";
		return new compiler.syntax.Parser(new compiler.syntax.Lexer(new compiler.Source.SourceFile(name + ".hx", source)).tokenize()).parseProgram()
			.classes[0];
	}

	static function argumentTypes(classes:Array<AstClass>, name:String):String {
		for (declaration in classes)
			if (declaration.name == name)
				for (method in declaration.methods)
					if (method.name == "new")
						return [for (argument in method.arguments) spelled(argument.type)].join(",");
		return "";
	}

	static function spelled(type:AstType):String
		return switch type {
			case IntType: "Int";
			case StringType: "String";
			case NamedType(name): name;
			default: Std.string(type);
		};

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}
}
