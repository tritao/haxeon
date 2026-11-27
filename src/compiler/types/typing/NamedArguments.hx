package compiler.types.typing;

import compiler.core.Diagnostic;
import compiler.core.Diagnostic.CompileError;
import compiler.core.DiagnosticCode;
import compiler.core.Source.SourceSpan;
import compiler.syntax.Ast.AstArgument;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.AstPredicates;

/**
 * Named arguments (`f(width: 10, height: 20)`): after its positional arguments, a call to a declared function may name the
 * parameters it passes, in the order they are declared. A parameter it skips before a named one must be optional and takes
 * its default; trailing ones are omitted as without names. Evaluation follows the order written, which is the parameters'.
 */
class NamedArguments {
	/** Whether a call names any of its arguments. */
	public static function any(arguments:Array<AstExpression>):Bool {
		for (argument in arguments)
			switch argument {
				case NamedArgument(_, _, _): return true;
				default:
			}
		return false;
	}

	/**
	 * The arguments of a call of `name` to a function with `parameters`, after `leading` ones typed already (a static
	 * extension's receiver), in positions: each named one at its parameter's, and a `DefaultArgument` in the place of each
	 * parameter skipped before a named one. Unchanged when no argument is named.
	 */
	public static function bind(parameters:Array<AstArgument>, arguments:Array<AstExpression>, leading:Int,
			name:String):Array<AstExpression> {
		var first = -1;
		for (index in 0...arguments.length)
			switch arguments[index] {
				case NamedArgument(_, _, _):
					first = index;
					break;
				default:
			}
		if (first < 0)
			return arguments;
		var bound = arguments.slice(0, first), next = leading + first;
		for (index in first...arguments.length)
			switch arguments[index] {
				case NamedArgument(argumentName, value, span):
					var position = -1;
					for (parameter in leading...parameters.length)
						if (parameters[parameter].name == argumentName) {
							position = parameter;
							break;
						}
					if (position < 0)
						fail('Function "$name" has no parameter named "$argumentName"', span);
					if (position < leading + first)
						fail('Parameter "$argumentName" of "$name" is given positionally already', span);
					if (position < next)
						fail('Parameter "$argumentName" of "$name" is named after a later one, or twice; name parameters in the order they are declared',
							span);
					if (RestArguments.isRest(parameters[position].type))
						fail('The rest parameter "$argumentName" of "$name" takes its arguments without a name', span);
					for (skipped in next...position) {
						var parameter = parameters[skipped];
						if (!AstPredicates.isOptionalArgument(parameter))
							fail('Call of "$name" skips the required parameter "${parameter.name}"', span);
						bound.push(DefaultArgument(span));
					}
					bound.push(value);
					next = position + 1;
				default:
					fail('A positional argument of "$name" follows a named one; named arguments come last',
						compiler.syntax.Parser.expressionSpan(arguments[index]));
			}
		return bound;
	}

	/** Whether `argument` is a parameter a call skipped, which takes its default. */
	public static inline function isDefault(argument:AstExpression):Bool
		return argument.match(DefaultArgument(_));

	static function fail(message:String, span:SourceSpan):Dynamic
		throw new CompileError(new Diagnostic(DiagnosticCode.CALL_FORM, message, span));
}
