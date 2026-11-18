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
	/**
	 * The prefix of the provisional name an object literal's structure has while its unit is typed and it can still gain optional
	 * fields (`MonomorphFrames.openStructure`). The name is replaced when the unit's frame is settled and never leaves the typer.
	 */
	public static final OPEN_STRUCTURE_PREFIX = "$anon:open:";

	/** Whether `name` is the provisional name of an object literal's open structure. */
	public static function isOpenStructureName(name:String):Bool
		return StringTools.startsWith(name, OPEN_STRUCTURE_PREFIX);

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

	/**
	 * Names the local `name`, declared at `span`, as the owner of each empty type variable in its type `type` that no local owns yet
	 * (`MonomorphCell.localName`): `var list = []` owns its element type, `var copy = list` does not take it over.
	 */
	public static function nameLocal(type:CompilerType, name:String, span:SourceSpan):Void
		switch follow(type) {
			case TMonomorph(cell):
				if (cell.localName == null) {
					cell.localName = name;
					cell.localSpan = span;
				}
			case TNullable(element), TArray(element), TIterator(element):
				nameLocal(element, name, span);
			case TMap(key, value):
				nameLocal(key, name, span);
				nameLocal(value, name, span);
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

	/**
	 * The first empty type variable in `type` that no later use hinted either (`MonomorphCell.hint`): what settling the frame it
	 * belongs to could only make Dynamic. Null when there is none.
	 */
	public static function firstUnfixed(type:CompilerType):Null<MonomorphCell>
		return contains(type) ? firstUnfixedWithin(resolve(type), []) : null;

	static function firstUnfixedWithin(type:CompilerType, visiting:Array<Array<AnonymousField>>):Null<MonomorphCell> {
		function first(types:Array<CompilerType>):Null<MonomorphCell> {
			for (part in types) {
				var found = firstUnfixedWithin(part, visiting);
				if (found != null)
					return found;
			}
			return null;
		}
		return switch type {
			case TMonomorph(cell): cell.hint == null ? cell : null;
			case TNullable(element), TArray(element), TIterator(element): firstUnfixedWithin(element, visiting);
			case TMap(key, value), TKeyPath(key, value, _): first([key, value]);
			case TFunction(arguments, result, _): first(arguments.concat([result]));
			case TInstance(_, _, arguments), TAbstract(_, arguments, _): first(arguments);
			case TAnonymous(_, fields):
				if (visiting.indexOf(fields) >= 0)
					null;
				else {
					visiting.push(fields);
					first([for (field in fields) field.type]);
				}
			default: null;
		};
	}

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
			// An open literal structure is one object for all its aliases: its own fields are resolved in place, so a field it gains
			// later is seen through every alias.
			case TAnonymous(name, fields) if (isOpenStructureName(name)):
				for (entry in anonymous)
					if (entry.from == fields)
						return entry.to;
				anonymous.push({from: fields, to: type});
				for (index in 0...fields.length) {
					var field = fields[index];
					if (containsWithin(field.type, null))
						fields[index] = {
							name: field.name,
							type: resolveWithin(field.type, anonymous),
							optional: field.optional,
							isFinal: field.isFinal
						};
				}
				type;
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
			// And a nullable meets its value's type: an optional unannotated argument `?x` stored in an Int field is a `Null<Int>`.
			case [TNullable(a), _] if (isUnbound(a) && !isNullish(right)):
				unify(a, right);
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

	/**
	 * Fills the empty type variable `type` with `value`, which, unlike what `unify` fills, may be Void or a nullable: what closes
	 * an unannotated function's result (`return;`, `return null`, no value return at all).
	 */
	public static function close(type:CompilerType, value:CompilerType):Void
		switch follow(type) {
			case TMonomorph(cell):
				cell.bound = value;
			default:
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
			// An open literal structure is filled in place, so `x.push({items: x})` must not make it contain itself.
			case TAnonymous(name, fields) if (isOpenStructureName(name)):
				for (field in fields)
					if (occurs(cell, field.type))
						return true;
				false;
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
