package compiler.types.typing;

import compiler.core.Source.SourceSpan;
import compiler.syntax.Ast.AstExpression;
import compiler.types.Type.CompilerType;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedSwitchArm;
import compiler.types.TypedAst.TypedSwitchArrayElement;
import compiler.types.TypedAst.TypedSwitchCoverageCase;
import compiler.types.analysis.Scope;

/** One value of a finite element type: an enum constructor, `true`, `false`, or a closed enum abstract value. */
private typedef ElementValue = {
	final name:String;
	final constructorIndex:Int;
	final key:Null<String>;
}

/**
 * `switch [a, b]`, as Haxe's matcher reads it: the subject is a tuple, never built as an array. Each element keeps its own
 * type, so `[IrInstruction, IrTerminator]` needs no common element type, every case is `_` or an array pattern with one
 * element per subject element, and the arms must cover every tuple unless the switch has a default.
 */
class TupleSwitch {
	/** The subject's elements when it is an array literal, which makes the switch a tuple switch; otherwise null. */
	public static function subjectElements(subject:AstExpression):Null<Array<AstExpression>>
		return switch subject {
			case ArrayLiteral(values, _): values;
			default: null;
		};

	/**
	 * Whether a switch over a value with no constants of its own (a structure, a class instance, a function) can match it: Haxe
	 * accepts one whose cases are `_`, names, captures of those, or `null`. It matches as the tuple switch of that one value
	 * (`wholeValue`, `wholeValuePattern`), so its cases bind and cover as a tuple's element does.
	 */
	public static function wholeValueCases(values:Array<AstExpression>):Bool {
		for (value in values)
			if (!isWholeValuePattern(value))
				return false;
		return true;
	}

	static function isWholeValuePattern(value:AstExpression):Bool
		return switch value {
			case Variable(name, _):
				var first = name.charCodeAt(0);
				name.indexOf(".") < 0 && first != null && (first == "_".code || first >= "a".code && first <= "z".code);
			case Capture(_, inner, _): isWholeValuePattern(inner);
			case NullLiteral(_): true;
			default: false;
		};

	/** The one-element tuple of a switch's subject (`wholeValueCases`). */
	public static function wholeValue(subject:TypedExpression):TypedExpression
		return new TypedExpression(TTuple([subject]), TVoid, subject.span);

	/** A case of a switch matched as `wholeValue`: the pattern of that one element. */
	public static function wholeValuePattern(value:AstExpression):AstExpression
		return ArrayLiteral([value], compiler.syntax.Parser.expressionSpan(value));

	/** The tuple subject: each element typed on its own, in source order, as Haxe evaluates them. */
	public static function typeSubject(bodyTyper:BodyTyping, values:Array<AstExpression>, span:SourceSpan,
			scope:Scope):TypedExpression
		return new TypedExpression(TTuple([for (value in values) bodyTyper.typeExpression(value, scope)]), TVoid, span);

	/** The element types of a tuple subject, or null when `subject` is an ordinary value. */
	public static function elementTypes(subject:TypedExpression):Null<Array<CompilerType>>
		return switch subject.expression {
			case TTuple(values): [for (value in values) value.type];
			default: null;
		};

	/**
	 * A tuple no unguarded arm matches, spelled as a pattern (`[Mov, _]`), or null when the arms cover every tuple.
	 *
	 * Columns are split one at a time, as Maranget's usefulness check does: an element type with finitely many values (an
	 * enum, Bool, a closed enum abstract) is covered value by value, any other only by `_`. A constructor pattern with
	 * nested argument patterns covers its constructor when the nested patterns do (`enumCaseCovered`), counting only arms
	 * whose later elements are all `_`. As in Haxe, `null` need not be matched: a null element no arm matches reaches the
	 * switch's unreachable fallback, which throws.
	 */
	public static function unmatched(session:TypingSession, bodyTyper:BodyTyping, types:Array<CompilerType>,
			arms:Array<TypedSwitchArm>, statement:Bool = false):Null<Array<String>> {
		var rows:Array<Array<TypedSwitchArrayElement>> = [];
		for (arm in arms)
			if (arm.guard == null) {
				var pattern = arm.arrayPattern;
				if (arm.isCatchAll || pattern == null)
					return null;
				rows.push(pattern.elements);
			}
		return missing(session, bodyTyper, types, rows, 0, statement);
	}

	/**
	 * E1021's message for the tuple `witness` no case matches (`unmatched`): of a tuple switch, `[Square, _]`; of a switch with
	 * structure patterns, whose tuple reads the fields at `columns` (`StructurePatterns`), `{shape: Square}`; or of a switch
	 * matched as its whole value (`wholeValueCases`), `_`.
	 */
	public static function missingCases(witness:Array<String>, columns:Null<Array<String>>, wholeValue:Bool):String {
		if (wholeValue)
			return 'Switch is missing cases: ${witness[0]}';
		if (columns != null)
			return 'Structure switch is missing cases: ${structureWitness(witness, columns)}';
		return 'Tuple switch is missing cases: [${witness.join(", ")}]';
	}

	/** The structure pattern of a tuple witness whose elements are the fields at `columns` ("" the subject, "a.b" a nested field). */
	static function structureWitness(witness:Array<String>, columns:Array<String>):String {
		var fields:Array<{path:String, value:String}> = [];
		for (index in 0...columns.length)
			if (columns[index] != "")
				fields.push({path: columns[index], value: witness[index]});
		return fields.length == 0 ? "_" : structureFields(fields, "");
	}

	static function structureFields(fields:Array<{path:String, value:String}>, prefix:String):String {
		var names:Array<String> = [], parts:Array<String> = [];
		for (field in fields)
			if (field.path.indexOf(prefix) == 0) {
				var rest = field.path.substr(prefix.length), dot = rest.indexOf(".");
				var name = dot < 0 ? rest : rest.substr(0, dot);
				if (names.indexOf(name) < 0)
					names.push(name);
			}
		for (name in names) {
			var path = prefix + name, nested = [for (field in fields) if (field.path.indexOf(path + ".") == 0) field];
			// A field matched by its own fields reads as their structure; one captured as a whole as its pattern.
			if (nested.length > 0)
				parts.push('$name: ${structureFields(nested, path + ".")}');
			else
				for (field in fields)
					if (field.path == path)
						parts.push('$name: ${field.value}');
		}
		return '{${parts.join(", ")}}';
	}

	static function missing(session:TypingSession, bodyTyper:BodyTyping, types:Array<CompilerType>,
			rows:Array<Array<TypedSwitchArrayElement>>, column:Int, statement:Bool):Null<Array<String>> {
		if (column == types.length)
			return rows.length > 0 ? null : [];
		var type = types[column],
			values = finiteValues(session, bodyTyper, type),
			wildcards = [for (row in rows) if (row[column].isCatchAll) row];
		if (statement && values == null && wildcards.length < rows.length) {
			var named = statementColumn(session, bodyTyper, types, rows, column);
			if (named != null)
				return named.witness;
		}
		if (values == null || wildcards.length == rows.length) {
			// A column every row leaves open is no decision: the next one is still the statement's first.
			var rest = missing(session, bodyTyper, types, wildcards, column + 1,
				statement && wildcards.length == rows.length);
			return rest == null ? null : ["_"].concat(rest);
		}
		for (value in values) {
			var full = [
				for (row in rows)
					if (row[column].isCatchAll || row[column].predicates.length == 0
					&& matches(bodyTyper, row[column], value))
					row
			],
				rest = missing(session, bodyTyper, types, full, column + 1, false);
			if (rest == null)
				continue;
			if (value.constructorIndex >= 0) {
				var alone:Array<TypedSwitchCoverageCase> = [
					for (row in rows)
						if (laterCatchAll(row, column) && (row[column].isCatchAll
						|| row[column].constructorIndex == value.constructorIndex))
						coverageCase(row[column])
				];
				if (bodyTyper.enumCaseCovered(type, value.constructorIndex, alone))
					continue;
			}
			return [value.name].concat(rest);
		}
		return null;
	}

	/**
	 * The first column a statement decides on, when its type has infinitely many values (Int, String), as Haxe's matcher reads it
	 * (`matcher.ml`, `Toplevel`): the values its cases name must each be covered by the rows that match them, but a value no case
	 * names need not be, so such a tuple runs no case. A later column, and any column of a switch used as a value, must be
	 * covered. Null when a case's pattern there is no constant, for which the column is checked as a value's.
	 */
	static function statementColumn(session:TypingSession, bodyTyper:BodyTyping, types:Array<CompilerType>,
			rows:Array<Array<TypedSwitchArrayElement>>, column:Int):Null<{witness:Null<Array<String>>}> {
		var keys:Array<String> = [];
		for (row in rows) {
			var element = row[column];
			if (element.isCatchAll)
				continue;
			var key = element.value == null
				|| element.predicates.length > 0 ? null : valueKey(bodyTyper, element.value);
			if (key == null)
				return null;
			if (keys.indexOf(key) < 0)
				keys.push(key);
		}
		for (key in keys) {
			var matching = [
				for (row in rows)
					if (row[column].isCatchAll || valueKey(bodyTyper, row[column].value) == key)
					row
			],
				rest = missing(session, bodyTyper, types, matching, column + 1, false);
			if (rest != null)
				return {witness: [key.substr(key.indexOf(":") + 1)].concat(rest)};
		}
		return {witness: null};
	}

	static function finiteValues(session:TypingSession, bodyTyper:BodyTyping,
			type:CompilerType):Null<Array<ElementValue>> {
		var enumName = BodyTyper.enumName(type);
		if (enumName != null) {
			var declaration = session.enumDecls.get(enumName);
			if (declaration == null)
				return null;
			return [for (index in 0...declaration.cases.length)
				{
					name:declaration.cases[index].name, constructorIndex:index, key:null
				}];
		}
		switch type {
			case TBool | TNullable(TBool):
				return [boolValue(true), boolValue(false)];
			default:
		}
		var closed = bodyTyper.closedEnumAbstractValues(type);
		return closed == null ? null : [for (value in closed)
			if (value.key != "null")
			{
				name:value.name, constructorIndex:-1, key:value.key
			}];
	}

	static function boolValue(value:Bool):ElementValue
		return {name: value ? "true" : "false", constructorIndex: -1, key: 'bool:$value'};

	static function matches(bodyTyper:BodyTyping, element:TypedSwitchArrayElement, value:ElementValue):Bool {
		if (value.constructorIndex >= 0)
			return element.constructorIndex == value.constructorIndex;
		var pattern = element.value;
		return pattern != null && valueKey(bodyTyper, pattern) == value.key;
	}

	static function valueKey(bodyTyper:BodyTyping, value:TypedExpression):Null<String>
		return switch value.expression {
			case TBoolLiteral(literal): 'bool:$literal';
			case TNullableWrap(inner), TCast(inner), TAbiCast(inner),
				TParameterConversion(inner, _): valueKey(bodyTyper, inner);
			default: bodyTyper.switchCaseKey(value, []);
		};

	static function laterCatchAll(row:Array<TypedSwitchArrayElement>, column:Int):Bool {
		for (index in column + 1...row.length)
			if (!row[index].isCatchAll)
				return false;
		return true;
	}

	static function coverageCase(element:TypedSwitchArrayElement):TypedSwitchCoverageCase
		return {
			constructorIndex: element.constructorIndex,
			subjectBinding: element.subjectBinding,
			isCatchAll: element.isCatchAll,
			guard: null,
			predicates: element.predicates
		};
}
