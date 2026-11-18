using compiler.compilation.BackendArtifact.BackendArtifacts;

import compiler.CompileOptions;
import compiler.Compiler;
import compiler.Compiler.CompileResult;
import compiler.hl.HlWriter;
import compiler.runtime.CompilerIntrinsics;
import compiler.semantic.SemanticSignature;
import compiler.types.Type.CompilerType;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedFunction;
import compiler.types.TypedAst.TypedStatement;

/**
 * A generic class's erased code made by the elaboration pass from its own-parameter typing (`--elaborate-generics`,
 * docs/design/GENERIC_TYPING_ONCE.md, stage 2) is the code typing it again gives, byte for byte, and each boundary the pass
 * makes says which conversion of a type parameter it stands for (`TypedExpression.parameterSource`). That survives a warm
 * rebuild that reuses the class's typed code and one that types it again.
 */
class GenericElaborationMain {
	static final BOX = [
		"class Box<T> {",
		"	final values:Array<T>;",
		"	public function new(values:Array<T>) this.values = values;",
		"	public function first():T return values.shift();",
		"}"
	];

	static function main():Void {
		var main = ["class Main {", "	static function main():Int return new Box([4, 5]).first();", "}"],
			edited = ["class Main {", "	static function main():Int return new Box([6, 5]).first() + 1;", "}"];
		var elaborated = compiler(true), plain = compiler(false);
		for (c in [elaborated, plain]) {
			c.update("Box.hx", BOX.join("\n"));
			c.update("Main.hx", main.join("\n"));
		}
		sameBytes("a fresh build", elaborated.compile("Main"), plain.compile("Main"));
		expectSource("a fresh build", elaborated);
		// The class is not typed again: its typed code is the previous build's.
		elaborated.update("Main.hx", edited.join("\n"));
		plain.update("Main.hx", edited.join("\n"));
		sameBytes("a warm rebuild that edits the user", elaborated.compile("Main"), plain.compile("Main"));
		expectSource("a warm rebuild that edits the user", elaborated);
		// The class is typed again.
		var box = BOX.copy();
		box[3] = "	public function first():T { var first = values.shift(); return first; }";
		elaborated.update("Box.hx", box.join("\n"));
		plain.update("Box.hx", box.join("\n"));
		sameBytes("a warm rebuild that edits the class", elaborated.compile("Main"), plain.compile("Main"));
		expectSource("a warm rebuild that edits the class", elaborated);
		Sys.println("PASS: a generic class's elaborated code is the code typed again, and its boundaries name their type parameter");
	}

	static function compiler(elaborate:Bool):Compiler {
		var c = new Compiler(null, CompilerIntrinsics.configuration());
		c.livePatching = false;
		c.options = new CompileOptions({elaborateGenerics: elaborate});
		c.addSourceRoot("stdlib");
		return c;
	}

	static function sameBytes(label:String, elaborated:CompileResult, plain:CompileResult):Void {
		var left = HlWriter.encode(elaborated.artifact.hashLink().module).flatten(),
			right = HlWriter.encode(plain.artifact.hashLink().module).flatten();
		if (left.compare(right) != 0)
			throw '$label: the elaborated build gives other bytes';
	}

	/** `Box.first` reads `Null<T>` as `T`: erased, that is a cast from `Null<Dynamic>`, made for `T`. */
	static function expectSource(label:String, c:Compiler):Void {
		var program = c.lastTypedProgram;
		if (program == null)
			throw '$label: no typed program';
		var first:Null<TypedFunction> = null;
		for (typedClass in program.classes)
			if (typedClass.name == "Box")
				for (method in typedClass.methods)
					if (method.name == "Box.first")
						first = method;
		if (first == null)
			throw '$label: Box.first was not typed';
		var found = sourceIn(first.statements);
		if (found == null)
			throw '$label: no boundary in Box.first names its type parameter';
		switch found {
			case TTypeParameter(_, "T") | TNullable(TTypeParameter(_, "T")):
			default: throw '$label: the boundary names ${SemanticSignature.type(found)}, not T';
		}
	}

	static function sourceIn(statements:Array<TypedStatement>):Null<CompilerType> {
		for (statement in statements) {
			var found = switch statement {
				case TReturn(value, _): sourceOf(value);
				case TVar(_, value, _): sourceOf(value);
				default: null;
			};
			if (found != null)
				return found;
		}
		return null;
	}

	static function sourceOf(value:TypedExpression):Null<CompilerType> {
		if (value.parameterSource != null)
			return value.parameterSource.source;
		return switch value.expression {
			case TCast(inner), TAbiCast(inner), TNullableWrap(inner), TCopy(inner, _),
				TToDynamic(inner): sourceOf(inner);
			case TBlockExpression(statements, result):
				var found = sourceIn(statements);
				found == null ? sourceOf(result) : found;
			default: null;
		};
	}
}
