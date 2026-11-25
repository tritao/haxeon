package compiler.types.typing;

import compiler.core.Source.SourceSpan;
import compiler.types.Type.CompilerType;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedSwitchArm;
import compiler.types.TypedAst.TypedSwitchPredicate;

/** One pattern position, as the null check reads it. */
private enum NullPattern {
	/** A wildcard or binding, or a pattern this check does not look into (array and structure patterns). */
	Any;

	/** `null`. */
	Null(type:CompilerType);

	/** An enum constructor with its argument patterns, or a constant (`true`, `X`, `1`) with none. */
	Value(key:String, name:String, type:CompilerType, arguments:Array<NullPattern>);
}

private typedef NullRow = {
	final patterns:Array<NullPattern>;
	final guarded:Bool;
}

/**
 * Haxe's rule for matching `null` in a switch without a default, for statement and expression switches alike.
 *
 * Haxe compiles a switch into a decision tree that switches on one value at a time: the first position the first remaining
 * case constrains (its columns swapped to the front), then the arguments of each matched constructor before the other
 * positions. The root switch need not match null: a null subject reaches the fallback, which fails with a null access. Every
 * switch below it over an explicitly nullable value with finitely many values (`Null<Enum>`, `Null<Bool>`, a nullable closed
 * enum abstract) must, either with `case null` or with a case that leaves that position unconstrained. So
 * `switch (instruction:Null<Ins>)` needs no `case null`, while `switch [a, b]` over a `Null<Term>` `b` that is matched by
 * constructor below a constructor of `a` does, and so does `C(J)`/`C(R)` for a `C(t:Null<Term>)` argument.
 *
 * Which constructors a switch covers is checked apart (`TupleSwitch.unmatched`, `enumCaseCovered`); this check only reports a
 * missing null.
 */
class SwitchNullCoverage {
	/**
	 * The arm a switch without a default ends with when its subject may be null and no arm matches null: `case null` throwing
	 * "Null access", what Haxe's root switch does with a null its arms leave (a closed enum abstract's implicit default throws
	 * for an undeclared value instead). Null when the subject is not nullable or an unguarded `case null` is among `seenCases`.
	 */
	public static function nullAccessArm(subject:TypedExpression, seenCases:Map<String, Bool>,
			span:SourceSpan):Null<TypedSwitchArm> {
		if (seenCases.exists("null"))
			return null;
		switch subject.type {
			case TNullable(_):
			default:
				return null;
		}
		return {
			value: new TypedExpression(TNullableWrap(new TypedExpression(TNullLiteral, TNull, span)), subject.type,
				span),
			subjectBinding: null,
			arrayPattern: null,
			isCatchAll: false,
			guard: null,
			enumName: null,
			constructorIndex: -1,
			bindings: [],
			predicates: [],
			span: span
		};
	}

	/** The `throw "Null access"` of `nullAccessArm`. */
	public static function nullAccess(span:SourceSpan):TypedExpression
		return new TypedExpression(TStringLiteral("Null access"), TString, span);

	/** A tuple no arm matches because one of its positions is a null nothing matches (`[B(_), null]`), or null. */
	public static function tupleWitness(session:TypingSession, bodyTyper:BodyTyping, types:Array<CompilerType>,
			arms:Array<TypedSwitchArm>):Null<Array<String>> {
		var rows:Array<NullRow> = [];
		for (arm in arms) {
			var pattern = arm.arrayPattern;
			if (arm.isCatchAll || pattern == null)
				rows.push({patterns: [for (_ in types) Any], guarded: arm.guard != null});
			else
				rows.push({patterns: [for (index in 0...types.length) {
					var element = pattern.elements[index];
					element.isCatchAll ? Any : position(session, bodyTyper, types[index], element.constructorIndex,
						element.value, element.predicates);
				}],
					guarded: arm.guard != null});
		}
		return missing(session, bodyTyper, rows, types.length, true);
	}

	/** A value no arm of a switch over `type` matches because a null below the subject is matched by nothing (`C(null)`). */
	public static function witness(session:TypingSession, bodyTyper:BodyTyping, type:CompilerType,
			arms:Array<TypedSwitchArm>):Null<String> {
		var rows:Array<NullRow> = [for (arm in arms)
			{
				patterns: [
					arm.isCatchAll ? Any : position(session, bodyTyper, type, arm.constructorIndex, arm.value,
						arm.predicates)
				], guarded: arm.guard != null
			}];
		var witness = missing(session, bodyTyper, rows, 1, true);
		return witness == null ? null : witness[0];
	}

	/** The pattern at one position: a constructor with the argument patterns its predicates spell, or a constant. */
	static function position(session:TypingSession, bodyTyper:BodyTyping, type:CompilerType, constructorIndex:Int,
			value:Null<TypedExpression>, predicates:Array<TypedSwitchPredicate>):NullPattern {
		if (constructorIndex >= 0)
			return constructor(session, bodyTyper, type, constructorIndex, [for (predicate in predicates)
				{
					path: [predicate.index].concat([for (access in predicate.nestedPath ?? []) access.fieldIndex]),
					predicate: predicate
				}]);
		return value == null ? Any : constant(bodyTyper, type, value);
	}

	static function constant(bodyTyper:BodyTyping, type:CompilerType, value:TypedExpression):NullPattern {
		var key = valueKey(bodyTyper, value);
		if (key == null)
			return Any;
		if (key == "null")
			return Null(type);
		// A closed enum abstract's value is shown by its name (`B`, not `2`).
		var name:Null<String> = null;
		for (declared in bodyTyper.closedEnumAbstractValues(type) ?? [])
			if (declared.key == key)
				name = declared.name;
		return Value(key, name ?? display(value, key), type, []);
	}

	/**
	 * Constructor `index` of the enum `type`, its arguments rebuilt from the flattened predicates of its payload: each entry's
	 * path is the field indices, from this constructor's down, that lead to the position its predicate constrains.
	 */
	static function constructor(session:TypingSession, bodyTyper:BodyTyping, type:CompilerType, index:Int,
			predicates:Array<{path:Array<Int>, predicate:TypedSwitchPredicate}>):NullPattern {
		var enumName = BodyTyper.enumName(type),
			declaration = enumName == null ? null : session.enumDecls.get(enumName);
		if (declaration == null || index >= declaration.cases.length)
			return Any;
		var enumCase = declaration.cases[index],
			arguments:Array<NullPattern> = [];
		for (field in 0...enumCase.params.length) {
			var own:Null<TypedSwitchPredicate> = null,
				below:Array<{path:Array<Int>, predicate:TypedSwitchPredicate}> = [];
			for (entry in predicates)
				if (entry.path.length > 0 && entry.path[0] == field) {
					if (entry.path.length == 1)
						own = entry.predicate;
					else
						below.push({path: entry.path.slice(1), predicate: entry.predicate});
				}
			arguments.push(argument(session, bodyTyper, own, below));
		}
		return Value('enum:$index', enumCase.name, type, arguments);
	}

	static function argument(session:TypingSession, bodyTyper:BodyTyping, own:Null<TypedSwitchPredicate>,
			below:Array<{path:Array<Int>, predicate:TypedSwitchPredicate}>):NullPattern {
		if (own == null || own.arrayIndex >= 0 || own.arrayLength >= 0
			|| (own.objectPath != null && own.objectPath.length > 0))
			return Any;
		var nested = own.nestedConstructorIndex;
		if (nested != null)
			return constructor(session, bodyTyper, own.type, nested, below);
		var value = own.value;
		if (value == null)
			return Any;
		var literal = BodyTyper.enumLiteral(value);
		return literal != null ? constructor(session, bodyTyper, own.type, literal.index, []) : constant(bodyTyper,
			own.type, value);
	}

	/**
	 * `patterns` with its first column replaced by a constructor's `arity` arguments: `arguments`, or wildcards for a row that
	 * matches any value there. Built only for the rows the constructor reaches.
	 */
	static function expandFirst(patterns:Array<NullPattern>, arguments:Null<Array<NullPattern>>,
			arity:Int):Array<NullPattern> {
		var result:Array<NullPattern> = [];
		for (index in 0...arity)
			result.push(arguments == null ? Any : arguments[index]);
		for (index in 1...patterns.length)
			result.push(patterns[index]);
		return result;
	}

	/**
	 * The missing positions of `rows` (one entry per column) when a switch below the root leaves a null unmatched, or null.
	 * Follows Haxe's matcher: the first row picks the column, which is swapped with the first one, and a constructor's
	 * arguments come before the remaining columns.
	 */
	static function missing(session:TypingSession, bodyTyper:BodyTyping, rows:Array<NullRow>, width:Int,
			root:Bool):Null<Array<String>> {
		if (rows.length == 0)
			return null;
		var first = rows[0],
			column = -1;
		for (index in 0...width)
			if (!isAny(first.patterns[index])) {
				column = index;
				break;
			}
		if (column < 0)
			return first.guarded ? missing(session, bodyTyper, rows.slice(1), width, root) : null;
		// Rows are never changed in place, so with the first column chosen they serve as they are.
		var swapped = column == 0 ? rows : [for (row in rows) {
			patterns: swap(row.patterns, column), guarded: row.guarded
		}];
		var type:Null<CompilerType> = null,
			values:Array<{key:String, name:String, arity:Int}> = [],
			seen:Map<String, Bool> = [],
			hasNull = false,
			hasAny = false;
		for (row in swapped)
			switch row.patterns[0] {
				case Any:
					hasAny = true;
				case Null(nullType):
					hasNull = true;
					if (type == null)
						type = nullType;
				case Value(key, name, valueType, arguments):
					if (type == null)
						type = valueType;
					if (!seen.exists(key)) {
						seen.set(key, true);
						values.push({key: key, name: name, arity: arguments.length});
					}
			}
		for (value in values) {
			var specialized:Array<NullRow> = [];
			for (row in swapped)
				switch row.patterns[0] {
					case Any:
						specialized.push({patterns: expandFirst(row.patterns, null, value.arity),
							guarded: row.guarded});
					case Value(key, _, _, arguments) if (key == value.key):
						specialized.push({
							patterns: expandFirst(row.patterns, arguments, value.arity),
							guarded: row.guarded
						});
					default:
				}
			var below = missing(session, bodyTyper, specialized, value.arity + width - 1, false);
			if (below != null) {
				var shown = value.arity == 0 ? value.name : '${value.name}(${below.slice(0, value.arity).join(", ")})';
				return swap([shown].concat(below.slice(value.arity)), column);
			}
		}
		if (!root && !hasNull && !hasAny && type != null && requiresNull(bodyTyper, type))
			return swap(["null"].concat([for (_ in 1...width) "_"]), column);
		// Below the constructors, the rows a null reaches (if one matches null) and those every other value reaches.
		// A switch that names every value of a finite type has no default, unless a null below the root reaches it.
		var finite = type == null ? -1 : valueCount(session, bodyTyper, type),
			reachedBy = hasNull ? [true] : [];
		if (finite < 0 || values.length < finite || (!root && requiresNull(bodyTyper, type)))
			reachedBy.push(false);
		for (nullCase in reachedBy) {
			var rest:Array<NullRow> = [];
			for (row in swapped) {
				var reaches = switch row.patterns[0] {
					case Any: true;
					case Null(_): nullCase;
					default: false;
				};
				if (reaches)
					rest.push({patterns: row.patterns.slice(1), guarded: row.guarded});
			}
			var below = missing(session, bodyTyper, rest, width - 1, false);
			if (below != null)
				return swap([nullCase ? "null" : "_"].concat(below), column);
		}
		return null;
	}

	/** How many values a finite type has (an enum's constructors, Bool's two, a closed enum abstract's), or -1. */
	static function valueCount(session:TypingSession, bodyTyper:BodyTyping, type:CompilerType):Int {
		switch type {
			case TBool | TNullable(TBool):
				return 2;
			default:
		}
		var enumName = BodyTyper.enumName(type);
		if (enumName != null) {
			var declaration = session.enumDecls.get(enumName);
			return declaration == null ? -1 : declaration.cases.length;
		}
		var closed = bodyTyper.closedEnumAbstractValues(type);
		return closed == null ? -1 : [for (value in closed) if (value.key != "null") value].length;
	}

	static function isAny(pattern:NullPattern):Bool
		return switch pattern {
			case Any: true;
			default: false;
		};

	/** Haxe's swap of the chosen column with the first. */
	static function swap<T>(row:Array<T>, column:Int):Array<T> {
		var result = row.copy();
		result[0] = row[column];
		result[column] = row[0];
		return result;
	}

	/** An explicitly nullable value with finitely many values, which a switch below the root must match null for. */
	static function requiresNull(bodyTyper:BodyTyping, type:CompilerType):Bool
		return switch type {
			case TNullable(TBool): true;
			case TNullable(inner): BodyTyper.isEnum(inner) || bodyTyper.closedEnumAbstractValues(inner) != null;
			default: false;
		};

	static function valueKey(bodyTyper:BodyTyping, value:TypedExpression):Null<String>
		return switch value.expression {
			case TBoolLiteral(literal): 'bool:$literal';
			case TNullableWrap(inner), TCast(inner), TAbiCast(inner),
				TParameterConversion(inner, _): valueKey(bodyTyper, inner);
			default: bodyTyper.switchCaseKey(value, []);
		};

	static function display(value:TypedExpression, key:String):String
		return switch value.expression {
			case TBoolLiteral(literal): '$literal';
			case TIntLiteral(literal): '$literal';
			case TStringLiteral(literal): '"$literal"';
			case TNullableWrap(inner), TCast(inner), TAbiCast(inner),
				TParameterConversion(inner, _): display(inner, key);
			default: key;
		};
}
