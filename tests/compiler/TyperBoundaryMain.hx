import compiler.Diagnostic.CompileError;
import compiler.Source.SourceFile;
import compiler.semantic.GenericSpecializationRegistry;
import compiler.semantic.SemanticProgram;
import compiler.syntax.Lexer;
import compiler.syntax.Parser;
import compiler.types.Typer;
import compiler.types.TypedAst.TypedProgram;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;
import compiler.types.TypeRelations;

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
		assertRecoveryTypeClassification();
		expect(specializations.exportState().length > 0, "generic calls should preserve emitted specialization state");
		expect(hasRuntimeDependency(measured.runtimeDependencies, "main", "Std"), "Float string conversion should retain the Std runtime dependency");
		assertDiagnostic("function main():Int { var value:Int; return value; }", "E1023", "may be used before assignment");
		assertDiagnostic("function identity(value:Int):Int return value; function main():Int return identity(\"wrong\");", "E1009", "argument 1");
		Sys.println("PASS: Typer subsystem boundaries preserve typed output and diagnostics");
	}

	static function assertRecoveryTypeClassification():Void {
		expect(!TypeRelations.containsRecovery(TInt), "primitive types should be stable");
		expect(!TypeRelations.containsRecovery(TTypeParameter("owner", "T")), "resolved type parameters should be stable");
		expect(!TypeRelations.containsRecovery(TFunction([TInt], TString)), "resolved function types should be stable");
		expect(TypeRelations.containsRecovery(TArray(TUnknown)), "recovery should be detected inside arrays");
		expect(TypeRelations.containsRecovery(TFunction([TInt], TError)), "recovery should be detected inside function results");
		expect(TypeRelations.containsRecovery(TInstance(NominalKind.Class, "Box", [TUnknown])),
			"recovery should be detected inside nominal arguments");
		expect(TypeRelations.containsRecovery(TAnonymous("Recovered", [{name: "value", type: TUnknown, optional: false}])),
			"recovery should be detected inside anonymous fields");
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
			if (fn.genericOrigin == "identity")
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
