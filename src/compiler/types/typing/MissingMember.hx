package compiler.types.typing;

import compiler.core.Diagnostic;
import compiler.core.DiagnosticCode;
import compiler.core.Source.SourceSpan;
import compiler.core.StdlibNames;
import compiler.semantic.SemanticSignature;
import compiler.types.FunctionTypes;
import compiler.types.Monomorphs;
import compiler.types.Type.CompilerType;

/**
 * A method call whose receiver has no member of that name (`String has no field trim`). The call (`CallResolver.typeMethodCall`)
 * then tries the static extensions (`StaticExtensions`), as Haxe tries them only once the value's own members have none; when no
 * extension applies either, the error stands as it is. `span` is the call's, which tells the call that failed apart from a call
 * among its arguments.
 */
class MissingMember extends CompileError {
	public final span:SourceSpan;

	/** `at` is where the error is reported when it stands, when that is not the call itself (the member's name). */
	public function new(code:DiagnosticCode, message:String, span:SourceSpan, ?at:SourceSpan) {
		super(new Diagnostic(code, message, at == null ? span : at));
		this.span = span;
	}

	/**
	 * Haxe's error for a member `owner` lacks (`haxe.io.Bytes has no field fill`, `Class<Foo> has no field make`), with the code
	 * of a missing field, at the member's name in `span`.
	 */
	public static function field(owner:String, name:String, span:SourceSpan):MissingMember
		return new MissingMember(DiagnosticCode.NAME_OR_MEMBER, '$owner has no field $name', span,
			AbstractProperties.nameSpan(span, name, true));

	/**
	 * `type` as Haxe spells it in that error: platform types by their Haxe paths, a structure by its fields, a function type as
	 * `Int -> Int` or `(Int, String) -> Void`.
	 */
	public static function haxeType(type:CompilerType):String
		return switch Monomorphs.follow(type) {
			case TBytes: StdlibNames.BYTES;
			case TNullable(element): 'Null<${haxeType(element)}>';
			case TArray(element): 'Array<${haxeType(element)}>';
			case TIterator(element): 'Iterator<${haxeType(element)}>';
			case TMap(key, value): 'haxe.ds.Map<${haxeType(key)}, ${haxeType(value)}>';
			case TAbstract(name, arguments, _), TInstance(_, name, arguments):
				arguments.length == 0 ? name : '$name<${[for (argument in arguments) haxeType(argument)].join(", ")}>';
			case TAnonymous(_, fields) if (fields.length == 0): "{ }";
			case TAnonymous(_, fields):
				'{ ${[for (field in fields) (field.optional ? "?" : "") + field.name + " : " + haxeType(field.type)].join(", ")} }';
			case TFunction(arguments, result, optional):
				var spelled = [
					for (index in 0...arguments.length)
						(FunctionTypes.isOptional(optional, index) ? "?" : "") + functionPart(arguments[index])
				];
				(arguments.length == 1 ? spelled[0] : '(${spelled.join(", ")})') + " -> " + functionPart(result);
			case followed: SemanticSignature.display(followed);
		};

	/** A function type's argument or result, parenthesized when it is a function type itself. */
	static function functionPart(type:CompilerType):String
		return switch Monomorphs.follow(type) {
			case TFunction(_, _, _): '(${haxeType(type)})';
			default: haxeType(type);
		};
}
