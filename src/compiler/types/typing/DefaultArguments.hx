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
 * and the function's prologue fills it.
 *
 * A parameter of a value type with a default (`x:Int = 7`: Int, Float, Bool, an enum, an abstract, a value class;
 * `valueDefault`) cannot hold null, so such a function has two entries. Its body is the direct entry, which takes the
 * value itself: a call whose target is known statically (a static or module function, a constructor, `super.f()`)
 * passes the default of that target's own declaration, unboxed. The dispatch entry (`dispatchName`) takes `Null<T>`
 * for each such parameter, as Haxe's HashLink generator does (it passes a reference there), replaces null with the
 * default and calls the body: interface and virtual calls, method values, function references and reflection use it,
 * and they pass null for an omitted argument. Which entries a function has, and their signatures, follow from its own
 * declaration alone.
 */
class DefaultArguments {
	static inline final DISPATCH_PREFIX = "$dispatch:";

	/** The dispatch entry of the function named `name`. */
	public static function dispatchName(name:String):String
		return DISPATCH_PREFIX + name;

	/** The function a dispatch entry named `name` calls, or null when `name` is not one. */
	public static function dispatchTarget(name:String):Null<String>
		return StringTools.startsWith(name, DISPATCH_PREFIX) ? name.substr(DISPATCH_PREFIX.length) : null;

	/** Whether `argument`, of `type`, has a default its type cannot represent the absence of: a dispatch entry fills it. */
	public static function valueDefault(argument:AstArgument, type:CompilerType, relations:TypeRelations):Bool
		return argument.defaultValue != null
			&& !AstPredicates.isNullExpression(argument.defaultValue)
			&& !holdsNull(type, relations)
			&& !isTypeParameter(type);

	/** `type` as the dispatch entry takes `argument`: nullable when it has a value default. */
	public static function dispatchType(argument:AstArgument, type:CompilerType, relations:TypeRelations):CompilerType
		return valueDefault(argument, type, relations) ? TNullable(type) : type;

	/** Whether a function declared with `arguments`, of `types`, has a dispatch entry. */
	public static function hasDispatchEntry(arguments:Array<AstArgument>, types:Array<CompilerType>,
			relations:TypeRelations):Bool {
		for (index in 0...arguments.length)
			if (valueDefault(arguments[index], types[index], relations))
				return true;
		return false;
	}

	static function isTypeParameter(type:CompilerType):Bool
		return switch type {
			case TTypeParameter(_, _): true;
			default: false;
		};
	/** Whether a function fills `argument`'s default itself, `type` being the argument's type. */
	public static function filledByCallee(argument:AstArgument, type:CompilerType, relations:TypeRelations):Bool
		return argument.defaultValue != null
			&& !AstPredicates.isNullExpression(argument.defaultValue)
			&& holdsNull(type, relations);

	/** The declaration keys of the parameters `withPrologue`'s prologue fills, `types` being the arguments'. */
	public static function filledDeclarations(arguments:Array<AstArgument>, types:Array<CompilerType>,
			relations:TypeRelations):Array<String>
		return [
			for (index in 0...arguments.length)
				if (filledByCallee(arguments[index], types[index], relations))
				compiler.types.analysis.BindingWalker.key(arguments[index].name, arguments[index].span)
		];

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
				// The parameter, by its declaration: a lambda's prologue is built after its body was resolved.
				prologue.push(If(Equal(DeclaredVariable(argument.name, span.start, span), NullLiteral(span), span), [
					DeclaredAssignment(argument.name, span.start, argument.defaultValue, span)
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
