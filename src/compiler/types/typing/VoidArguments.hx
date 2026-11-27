package compiler.types.typing;

import compiler.core.Source.SourceSpan;
import compiler.syntax.Ast.AstArgument;
import compiler.syntax.Ast.AstExpression;
import compiler.types.Type.CompilerType;

/**
 * `Void` as the unit type at calls (docs/design/ERROR_MODEL.md): a parameter whose type is `Void`, written or substituted for
 * a type parameter, takes no argument, so `Ok()` makes a `Result<Void, E>` and `() -> 1` is a `Void->Int`. The omitted
 * argument is the unit value (`EmptyExpression`), so a typed call still has one argument per parameter.
 */
class VoidArguments {
	public static function isVoid(type:Null<CompilerType>):Bool
		return type != null && compiler.types.Monomorphs.follow(type).match(TVoid);

	/**
	 * Where the unit value goes when `written` arguments are given for parameters of `types`: at a `Void` parameter while
	 * more parameters remain than arguments, so a `Void` value written in its place still takes it. Null when none does.
	 */
	static function unitPositions(written:Int, types:Array<CompilerType>):Null<Array<Bool>> {
		if (written >= types.length)
			return null;
		var positions:Array<Bool> = [], next = 0, any = false;
		for (index in 0...types.length) {
			if (isVoid(types[index]) && types.length - index > written - next) {
				positions.push(true);
				any = true;
			} else if (next < written) {
				positions.push(false);
				next++;
			} else
				break;
		}
		return any ? positions : null;
	}

	/** `arguments` of a call to parameters of `types`, with the unit value for each `Void` parameter they leave out. */
	public static function fill(arguments:Array<AstExpression>, types:Array<CompilerType>,
			span:SourceSpan):Array<AstExpression> {
		var positions = unitPositions(arguments.length, types);
		if (positions == null)
			return arguments;
		var filled:Array<AstExpression> = [], next = 0;
		for (unit in positions)
			filled.push(unit ? EmptyExpression(span) : arguments[next++]);
		return filled;
	}

	/** A lambda's `arguments` for a function type of `types`, with an unused one for each `Void` argument they leave out. */
	public static function fillParameters(arguments:Array<AstArgument>, types:Array<CompilerType>,
			span:SourceSpan):Array<AstArgument> {
		var positions = unitPositions(arguments.length, types);
		if (positions == null)
			return arguments;
		var filled:Array<AstArgument> = [], next = 0;
		for (unit in positions)
			filled.push(unit ? {name: "_", type: InferredType, span: span} : arguments[next++]);
		return filled;
	}
}
