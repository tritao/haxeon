import compiler.Diagnostic.CompileError;
import compiler.Source.SourceFile;
import compiler.semantic.GenericSpecializationRegistry;
import compiler.semantic.SemanticProgram;
import compiler.syntax.Lexer;
import compiler.syntax.Parser;
import compiler.types.Typer;
import compiler.types.TypedAst.TypedProgram;

class TyperBoundaryMain {
	static function main():Void {
		var source = 'typedef Entry = {name:String, index:Int}; '
			+ 'abstract Value<T>(T) { public function new(value:T) { this = value; } } '
			+ 'class Box<T> { public var value:T; public function new(value:T) this.value = value; } '
			+ 'function identity<T>(value:T):T return value; '
			+ 'function entries(values:Map<String, Int>):Array<Entry> return [for (name => index in values) {name: name, index: index}]; '
			+ 'function main():Int { var box = new Box(42); var wrapped = new Value<Int>(box.value); '
			+ 'var captured = (extra:Int) -> box.value + extra; var numbers:Array<Int> = [20, 22]; '
			+ 'var selected = switch numbers[0] { case 20: captured(22); default: 0; }; '
			+ 'var dictionary:Map<String, Int> = ["answer" => selected]; var projected = entries(dictionary); '
			+ 'var copied = identity(projected[0].index); var maybe:Null<Int> = null; var dynamicValue:Dynamic = maybe; '
			+ 'var text = "answer=" + 1.5; return copied; }';
		var program = parse("TyperBoundary.hx", source),
			specializations = new GenericSpecializationRegistry(),
			measured = Typer.typeAnalyzedMeasured(SemanticProgram.analyze(program), null, null, null, specializations),
			typed = measured.program;
		assertProgramShape(typed);
		expect(specializations.exportState().length > 0, "generic calls should preserve emitted specialization state");
		expect(hasRuntimeDependency(measured.runtimeDependencies, "main", "Std"), "Float string conversion should retain the Std runtime dependency");
		assertDiagnostic("function main():Int { var value:Int; return value; }", "E1023", "may be used before assignment");
		assertDiagnostic("function identity(value:Int):Int return value; function main():Int return identity(\"wrong\");", "E1009", "argument 1");
		// Value class instances are stored inline in fields, so null cannot reach one; it used to segfault at runtime.
		var value = "@:value class V { public var x:Int; public function new(x:Int) this.x = x; } ";
		assertDiagnostic(value
			+ "class H { public var v:V; public function new() v = new V(1); } function main():Int { var h = new H(); h.v = null; return 0; }", "E1002",
			"");
		assertDiagnostic(value + "class H { public var v:V; public function new(?v:V) this.v = v; } function main():Int { return 0; }", "E1002", "");
		assertDiagnostic(value + "class H { public var v:Null<V>; public function new() {} } function main():Int { return 0; }", "E1022", "cannot be Null<V>");
		// `inline` on functions and methods is recorded on the typed function (the inliner uses it as a hint).
		var inlineProgram = Typer.type(parse("InlineFlag.hx",
			"inline function f():Int return 1; function g():Int return 2; " +
			"class C { public inline function m():Int return 3; public function n():Int return 4; public function new() {} } " +
			"function main():Int return f() + g() + new C().m() + new C().n();"));
		var inlineFlags:Map<String, Bool> = [];
		for (fn in inlineProgram.functions)
			inlineFlags.set(fn.name, fn.isInline == true);
		expect(inlineFlags.get("f") == true && inlineFlags.get("C.m") == true, "inline functions and methods should carry the inline flag");
		expect(inlineFlags.get("g") == false && inlineFlags.get("C.n") == false, "ordinary functions and methods should not carry the inline flag");
		Sys.println("PASS: Typer subsystem boundaries preserve typed output and diagnostics");
	}

	static function assertProgramShape(program:TypedProgram):Void {
		expect(program.classes.length == 1 && program.classes[0].name == "Box", "program typing should retain the class shell");
		expect(program.anonymousTypes.length == 1
			&& program.anonymousTypes[0].fields.length == 2, "anonymous type registration should retain the Entry shape");
		expect(program.closurePlan.environments.length == 1, "closure typing should retain its captured environment");
		var hasMain = false,
			hasIdentitySpecialization = false,
			hasLambda = false;
		for (fn in program.functions) {
			if (fn.name == "main")
				hasMain = true;
			if (fn.origin == "identity" && fn.originKind == compiler.types.TypedAst.FunctionOriginKind.Specialization)
				hasIdentitySpecialization = true;
			if (StringTools.startsWith(fn.name, "$" + "lambda:"))
				hasLambda = true;
		}
		expect(hasMain && hasIdentitySpecialization && hasLambda, "body typing should retain main, generic, and generated lambda functions");
	}

	static function assertDiagnostic(source:String, code:String, messagePart:String):Void {
		try {
			Typer.type(parse("TyperBoundaryError.hx", source));
			throw 'Expected $code diagnostic';
		} catch (error:CompileError) {
			expect(error.diagnostic.code == code, 'Expected diagnostic $code, got ${error.diagnostic.code}');
			expect(error.diagnostic.message.indexOf(messagePart) >= 0, 'Diagnostic did not contain "$messagePart"');
			expect(error.diagnostic.span.file.path == "TyperBoundaryError.hx", "diagnostics should retain their source file");
		}
	}

	static function hasRuntimeDependency(dependencies:Array<{final functionName:String; final target:String;}>, functionName:String, target:String):Bool {
		for (dependency in dependencies)
			if (dependency.functionName == functionName && dependency.target == target)
				return true;
		return false;
	}

	static function parse(path:String, source:String):compiler.syntax.Ast.AstProgram
		return new Parser(new Lexer(new SourceFile(path, source)).tokenize()).parseProgram();

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}
}
