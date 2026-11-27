package compiler.types.typing;

import compiler.core.Diagnostic;
import compiler.core.Diagnostic.CompileError;
import compiler.core.DiagnosticCode;
import compiler.core.Source.SourceSpan;
import compiler.syntax.Ast.AstArgument;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstType;
import compiler.core.StdlibNames;

/**
 * Haxe's rest parameters (`function f(...values:Int)`): a last parameter of type `haxe.Rest<T>` receives the arguments from its
 * position on, which the call passes packed in an array (`f(1, 2, 3)` passes `[1, 2, 3]`, `f()` an empty one), or an array of
 * them as it is (`f(...array)`), which `haxe.Rest` holds. A function's value is called with the `haxe.Rest` itself.
 */
class RestArguments {
	/** Whether `type` is a rest parameter's, `haxe.Rest<T>`. */
	public static function isRest(type:AstType):Bool
		return switch type {
			case AppliedType(StdlibNames.REST, [_]): true;
			default: false;
		};

	/**
	 * The arguments of a call to a function with `parameters`, after `leading` arguments typed already: those a rest parameter
	 * receives packed into one, or its spread array as it is. Unchanged when the last parameter is not a rest parameter.
	 */
	public static function pack(parameters:Array<AstArgument>, arguments:Array<AstExpression>, leading:Int,
			span:SourceSpan):Array<AstExpression> {
		if (parameters.length == 0 || !isRest(parameters[parameters.length - 1].type)) {
			rejectSpread(arguments);
			return arguments;
		}
		return packAt(parameters.length - 1 - leading, arguments, span);
	}

	/** Whether a function type's argument is a rest parameter's, `haxe.Rest<T>`: a function value is called as its function is. */
	public static function isRestValue(type:compiler.types.Type.CompilerType):Bool
		return switch type {
			case TAbstract(StdlibNames.REST, [_], _): true;
			default: false;
		};

	/** The arguments with those from `restIndex` on packed for the rest parameter there, or its spread array as it is. */
	public static function packAt(restIndex:Int, arguments:Array<AstExpression>, span:SourceSpan):Array<AstExpression> {
		if (restIndex < 0 || arguments.length < restIndex) {
			rejectSpread(arguments);
			return arguments;
		}
		var fixed = arguments.slice(0, restIndex), rest = arguments.slice(restIndex);
		rejectSpread(fixed);
		if (rest.length == 1)
			switch rest[0] {
				case Spread(array, _):
					fixed.push(array);
					return fixed;
				default:
			}
		rejectSpread(rest);
		var restSpan = rest.length == 0 ? span : compiler.syntax.Parser.expressionSpan(rest[0])
			.merge(compiler.syntax.Parser.expressionSpan(rest[rest.length - 1]));
		fixed.push(ArrayLiteral(rest, restSpan));
		return fixed;
	}

	/** A spread passes a rest argument only, alone and last. */
	public static function rejectSpread(arguments:Array<AstExpression>):Void
		for (argument in arguments)
			switch argument {
				case Spread(_, span):
					throw new CompileError(new Diagnostic(DiagnosticCode.CALL_FORM,
						"A spread `...values` passes a rest argument, as a call's last argument", span));
				default:
			}
}
