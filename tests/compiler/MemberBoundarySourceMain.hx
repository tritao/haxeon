using compiler.compilation.BackendArtifact.BackendArtifacts;

import compiler.CompileOptions;
import compiler.Compiler;
import compiler.runtime.CompilerIntrinsics;
import compiler.semantic.SemanticSignature;
import compiler.types.Type.CompilerType;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedFunction;
import compiler.types.TypedAst.TypedStatement;

/**
 * Reading a field of a generic class's value through its erased code, or calling a method whose result is a type parameter,
 * casts the erased value to the caller's type (`Dynamic` to `Int` for a `Box<Int>`). That cast says which declared type it
 * stands for (`TypedExpression.parameterSource`: `T`, and `T` as `Int`), so lowering can use what the caller knows. It does
 * so after a warm rebuild that types the reader again, and after one that keeps the reader's typed code.
 */
class MemberBoundarySourceMain {
	static final BOX = [
		"class Box<T> {",
		"	public var value:T;",
		"	public function new(value:T) this.value = value;",
		"	public function get():T return value;",
		"}"
	];

	static function main():Void {
		var main = [
			"class Main {",
			"	static function main():Int {",
			"		var box = new Box(4);",
			"		var read:Int = box.value;",
			"		var called:Int = box.get();",
			"		return read + called;",
			"	}",
			"}"
		];
		var c = new Compiler(null, CompilerIntrinsics.configuration());
		c.livePatching = false;
		c.options = new CompileOptions();
		c.addSourceRoot("stdlib");
		c.update("Box.hx", BOX.join("\n"));
		c.update("Main.hx", main.join("\n"));
		c.compile("Main");
		expectSources("a fresh build", c);
		var edited = main.copy();
		edited[5] = "		return read + called + 1;";
		c.update("Main.hx", edited.join("\n"));
		c.compile("Main");
		expectSources("a warm rebuild that edits the reader", c);
		var box = BOX.copy();
		box.insert(4, "	public function size():Int return 1;");
		c.update("Box.hx", box.join("\n"));
		c.compile("Main");
		expectSources("a warm rebuild that edits the class", c);
		Sys.println("PASS: a read and a call through a generic class's erased code name the type parameter they cast");
	}

	static function expectSources(label:String, c:Compiler):Void {
		var program = c.lastTypedProgram;
		if (program == null)
			throw '$label: no typed program';
		var main:Null<TypedFunction> = null;
		for (fn in program.functions)
			if (fn.name == "Main.main")
				main = fn;
		for (typedClass in program.classes)
			for (method in typedClass.methods)
				if (method.name == "Main.main")
					main = method;
		if (main == null)
			throw '$label: Main.main was not typed';
		for (name in ["read", "called"]) {
			var source = declaredSource(main.statements, name);
			if (source == null)
				throw '$label: the cast that gives "$name" names no type parameter';
			switch source.source {
				case TTypeParameter(_, "T"):
				default: throw '$label: the cast that gives "$name" names ${SemanticSignature.type(source.source)}, not T';
			}
			var argument = source.substitutions.get("T");
			if (argument == null || !argument.match(TInt))
				throw '$label: the cast that gives "$name" does not substitute Int for T';
		}
	}

	static function declaredSource(statements:Array<TypedStatement>,
			name:String):Null<{
				source:CompilerType,
				substitutions:Map<String, CompilerType>
			}> {
		for (statement in statements)
			switch statement {
				// A local is named after its binding (`$l1:read`).
				case TVar(local, value, _) if (local == name || StringTools.endsWith(local, ":" + name)):
					return sourceOf(value);
				default:
			}
		return null;
	}

	static function sourceOf(value:TypedExpression):Null<{source:CompilerType,
		substitutions:Map<String, CompilerType>}> {
		var found = value.parameterSource;
		if (found != null)
			return {source: found.source, substitutions: found.substitutions};
		return switch value.expression {
			case TCast(inner), TAbiCast(inner), TNullableWrap(inner): sourceOf(inner);
			default: null;
		};
	}
}
