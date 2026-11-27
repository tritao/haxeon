package compiler.types.typing;

import compiler.types.Type.CompilerType;

/**
 * `Void` as the unit type where something is written for each parameter (docs/design/ERROR_MODEL.md): a parameter whose
 * type is `Void`, written or substituted for a type parameter, may be left out, so `Ok()` makes a `Result<Void, E>`,
 * `case Ok():` matches it and `() -> 1` is a `Void->Int`. What is left out is filled in, so a typed call, lambda or pattern
 * still has one item per parameter.
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

	/**
	 * What is written for parameters of `types` (a call's arguments, a lambda's arguments or a pattern's bindings), with
	 * `unit` at each `Void` parameter it leaves out. One rule serves all three, so a case is matched as it is made.
	 */
	public static function fill<A>(written:Array<A>, types:Array<CompilerType>, unit:A):Array<A> {
		var positions = unitPositions(written.length, types);
		if (positions == null)
			return written;
		var filled:Array<A> = [], next = 0;
		for (isUnit in positions)
			filled.push(isUnit ? unit : written[next++]);
		return filled;
	}
}
