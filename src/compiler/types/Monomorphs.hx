package compiler.types;

import compiler.core.Source.SourceSpan;
import compiler.types.Type.AnonymousField;
import compiler.types.Type.CompilerType;
import compiler.types.Type.MonomorphCell;

/**
 * Type variables for locals whose type the code fixes later than it declares them, as Haxe infers them: `var list = []`
 * is an `Array<?>` until a `push` fixes the element, `var x;` and `var x = null` until the first assignment does.
 *
 * A type variable is made only while a body is typed and is filled at most once, by `unify`, where a value meets the type
 * it must have (`ConversionResolver.coerce`). It never leaves the typer: when the body is typed, every filled one is
 * replaced by its type throughout what the body made (`TypedTypeMap`), and one still empty becomes Dynamic, as in Haxe
 * (`BodyTyper.settleFrame`).
 */
class Monomorphs {
	/** The type `type` stands for: a filled type variable's type, followed through chains, or `type` itself. */
	public static function follow(type:CompilerType):CompilerType {
		var current = type;
		while (true)
			switch current {
				case TMonomorph(cell):
					var bound = cell.bound;
					if (bound == null)
						return current;
					current = bound;
				default:
					return current;
			}
	}

	/** Whether `type` is an empty type variable. */
	public static function isUnbound(type:CompilerType):Bool
		return switch follow(type) {
			case TMonomorph(_): true;
			default: false;
		};

	/**
	 * What typing a value expected to be `type` should expect: the hint of an empty type variable (or nothing, without one),
	 * and otherwise `type` with its filled variables resolved.
	 */
	public static function expectation(type:CompilerType):Null<CompilerType>
		return switch follow(type) {
			case TMonomorph(cell): cell.hint == null ? null : resolve(cell.hint);
			default: resolve(type);
		};

	/** Records `expected` as the hint of each empty type variable in `type`, part by part (`MonomorphCell.hint`). */
	public static function hint(type:CompilerType, expected:CompilerType):Void
		switch [follow(type), follow(expected)] {
			case [TMonomorph(cell), _]:
				if (cell.hint == null)
					cell.hint = expected;
			case [TNullable(a), TNullable(b)], [TArray(a), TArray(b)], [TIterator(a), TIterator(b)]:
				hint(a, b);
			case [TNullable(a), _]:
				hint(a, expected);
			case [TMap(k1, v1), TMap(k2, v2)]:
				hint(k1, k2);
				hint(v1, v2);
			default:
		}

	/** Whether `type` mentions a type variable, filled or not. */
	public static function contains(type:CompilerType):Bool
		return containsWithin(type, null);

	/** `visiting` holds the structures being walked: a recursive one (`typedef Tree = {children:Array<Tree>}`) is entered once. */
	static function containsWithin(type:CompilerType, visiting:Null<Array<Array<AnonymousField>>>):Bool
		return switch type {
			case TMonomorph(_): true;
			case TNullable(element), TArray(element), TIterator(element): containsWithin(element, visiting);
			case TMap(key, value): containsWithin(key, visiting) || containsWithin(value, visiting);
			case TKeyPath(root, value, _): containsWithin(root, visiting) || containsWithin(value, visiting);
			case TFunction(arguments, result, _):
				if (containsWithin(result, visiting))
					return true;
				for (argument in arguments)
					if (containsWithin(argument, visiting))
						return true;
				false;
			case TInstance(_, _, arguments), TAbstract(_, arguments, _):
				for (argument in arguments)
					if (containsWithin(argument, visiting))
						return true;
				false;
			case TAnonymous(_, fields): anonymousContains(fields, visiting == null ? [] : visiting);
			default: false;
		};

	static function anonymousContains(fields:Array<AnonymousField>, visiting:Array<Array<AnonymousField>>):Bool {
		for (seen in visiting)
			if (seen == fields)
				return false;
		visiting.push(fields);
		for (field in fields)
			if (containsWithin(field.type, visiting))
				return true;
		return false;
	}

	/** Whether `type` mentions a type variable nothing has filled yet. */
	public static function containsUnbound(type:CompilerType):Bool
		return contains(type) && contains(resolve(type));

	/** `type` with every filled type variable replaced by its type; `type` itself when it mentions none. */
	public static function resolve(type:CompilerType):CompilerType
		return contains(type) ? resolveWithin(type, []) : type;

	static function resolveWithin(type:CompilerType,
			anonymous:Array<{from:Array<AnonymousField>, to:CompilerType}>):CompilerType
		return switch type {
			case TMonomorph(cell):
				var bound = cell.bound;
				bound == null ? type : resolveWithin(bound, anonymous);
			case TNullable(element): TNullable(resolveWithin(element, anonymous));
			case TArray(element): TArray(resolveWithin(element, anonymous));
			case TIterator(element): TIterator(resolveWithin(element, anonymous));
			case TMap(key, value): TMap(resolveWithin(key, anonymous), resolveWithin(value, anonymous));
			case TKeyPath(root, value, writable): TKeyPath(resolveWithin(root, anonymous),
				resolveWithin(value, anonymous),
				writable);
			case TFunction(arguments,
				result, optional): TFunction([for (argument in arguments) resolveWithin(argument, anonymous)],
				resolveWithin(result, anonymous), optional);
			case TInstance(kind, name, arguments): TInstance(kind, name,
				[for (argument in arguments) resolveWithin(argument,
				anonymous)]);
			case TAbstract(name, arguments, representation): TAbstract(name,
				[for (argument in arguments) resolveWithin(argument,
				anonymous)], resolveWithin(representation, anonymous));
			case TAnonymous(name, fields):
				if (!anonymousContains(fields, []))
					type;
				else {
					for (entry in anonymous)
						if (entry.from == fields)
							return entry.to;
					var resolvedFields:Array<AnonymousField> = [];
					var result = TAnonymous(name, resolvedFields);
					anonymous.push({from: fields, to: result});
					for (field in fields)
						resolvedFields.push({
							name: field.name,
							type: resolveWithin(field.type, anonymous),
							optional: field.optional,
							isFinal: field.isFinal
						});
					result;
				}
			default: type;
		};

	/**
	 * Makes `actual` and `expected` the same type where one of them has an empty type variable, by filling it from the other
	 * side, part by part: `Array<?>` meeting `Array<Int>` fills `?` with Int. Parts that differ otherwise are left for the
	 * caller's own check. A variable is not filled with a type that mentions it, nor with Null, Void or Never, which do not
	 * fix a local's type.
	 */
	public static function unify(actual:CompilerType, expected:CompilerType):Void {
		var left = follow(actual), right = follow(expected);
		switch [left, right] {
			case [TMonomorph(a), TMonomorph(b)]:
				if (a != b)
					a.bound = right;
			case [TMonomorph(cell), _]:
				fill(cell, right);
			case [_, TMonomorph(cell)]:
				fill(cell, left);
			case [TNullable(a), TNullable(b)], [TArray(a), TArray(b)], [TIterator(a), TIterator(b)]:
				unify(a, b);
			// A value converts to its nullable: what fixes `?` in `Null<?>` is the value's own type.
			case [_, TNullable(b)] if (isUnbound(b) && !isNullish(left)):
				unify(left, b);
			case [TMap(k1, v1), TMap(k2, v2)]:
				unify(k1, k2);
				unify(v1, v2);
			case [TFunction(a1, r1, _), TFunction(a2, r2, _)] if (a1.length == a2.length):
				for (index in 0...a1.length)
					unify(a2[index], a1[index]);
				unify(r1, r2);
			case [TInstance(k1, n1, a1), TInstance(k2, n2, a2)] if (k1 == k2 && (n1:String) == (n2:String)
				&& a1.length == a2.length):
				for (index in 0...a1.length)
					unify(a1[index], a2[index]);
			default:
		}
	}

	static function fill(cell:MonomorphCell, type:CompilerType):Void {
		if (isNullish(type) || occurs(cell, type))
			return;
		cell.bound = type;
	}

	static function isNullish(type:CompilerType):Bool
		return switch type {
			case TNull, TVoid, TNever: true;
			default: false;
		};

	static function occurs(cell:MonomorphCell, type:CompilerType):Bool
		return switch follow(type) {
			case TMonomorph(other): other == cell;
			case TNullable(element), TArray(element), TIterator(element): occurs(cell, element);
			case TMap(key, value): occurs(cell, key) || occurs(cell, value);
			case TFunction(arguments, result, _):
				if (occurs(cell, result))
					return true;
				for (argument in arguments)
					if (occurs(cell, argument))
						return true;
				false;
			case TInstance(_, _, arguments), TAbstract(_, arguments, _):
				for (argument in arguments)
					if (occurs(cell, argument))
						return true;
				false;
			default: false;
		};
}
