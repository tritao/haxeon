package compiler.types.typing;

import compiler.syntax.Ast.AstArgument;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstFunction;
import compiler.syntax.Ast.AstStatement;
import compiler.syntax.AstFunctions;
import compiler.syntax.AstPredicates;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;
import compiler.types.TypeRelations;

/**
 * Where a parameter's default value is filled in. Haxe fills it in the function, on HashLink as on its other static
 * targets: an omitted argument is passed as null, and the function replaces a null argument with its own default. A
 * call through an interface or a base class therefore gets the default of the method that runs, never the one of the
 * receiver's static type (a default an interface method declares is never used), and an explicit null gets the default
 * too.
 *
 * Haxeon does the same for a parameter whose type holds null by reference: strings, class and interface instances,
 * arrays, maps, functions, structures, Dynamic and `Null<T>`. A virtual call passes null for such an omitted argument,
 * and the function's prologue fills it. A parameter of another type (Int, Float, Bool, an enum, an abstract, a value
 * class) takes its default at the call site from the static signature, as a direct call takes every default: holding
 * null would box the argument of every call.
 */
class DefaultArguments {
	/** Whether a function fills `argument`'s default itself, `type` being the argument's type. */
	public static function filledByCallee(argument:AstArgument, type:CompilerType, relations:TypeRelations):Bool
		return argument.defaultValue != null
			&& !AstPredicates.isNullExpression(argument.defaultValue)
			&& holdsNull(type, relations);

	/** `fn` with the prologue of `withPrologue`; `types` are its arguments'. */
	public static function withFunctionPrologue(fn:AstFunction, types:Array<CompilerType>,
			relations:TypeRelations):AstFunction {
		var statements = withPrologue(fn.arguments, types, fn.statements, relations);
		return statements == fn.statements ? fn : AstFunctions.copy(fn, fn.name, fn.isStatic, fn.metadata,
			fn.typeParameters, fn.typeConstraints, fn.arguments, fn.result, statements, fn.span);
	}

	/**
	 * A body that first replaces each null argument the function fills itself with its default; `types` are the arguments'.
	 * Every kind of function gets it, the same way: methods and module functions (`BodyTyper.typeFunction`), local functions
	 * and lambdas (`ClosureTyper.typeLambda`).
	 */
	public static function withPrologue(arguments:Array<AstArgument>, types:Array<CompilerType>,
			statements:Array<AstStatement>, relations:TypeRelations):Array<AstStatement> {
		var prologue:Array<AstStatement> = [];
		for (index in 0...arguments.length) {
			var argument = arguments[index];
			if (filledByCallee(argument, types[index], relations)) {
				var span = argument.span;
				prologue.push(If(Equal(Variable(argument.name, span), NullLiteral(span), span), [
					Assignment(argument.name, argument.defaultValue, span)
				], [], span));
			}
		}
		return prologue.length == 0 ? statements : prologue.concat(statements);
	}

	static function holdsNull(type:CompilerType, relations:TypeRelations):Bool
		return switch type {
			case TString, TDynamic, TNullable(_), TArray(_), TMap(_, _), TFunction(_, _, _), TAnonymous(_, _): true;
			case TInstance(NominalKind.Class, _, _): !relations.isValueClass(type);
			case TInstance(NominalKind.Interface, _, _): true;
			default: false;
		};
}
