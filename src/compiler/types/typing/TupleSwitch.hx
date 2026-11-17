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
			arms:Array<TypedSwitchArm>):Null<String> {
		var rows:Array<Array<TypedSwitchArrayElement>> = [];
		for (arm in arms)
			if (arm.guard == null) {
				var pattern = arm.arrayPattern;
				if (arm.isCatchAll || pattern == null)
					return null;
				rows.push(pattern.elements);
			}
		var witness = missing(session, bodyTyper, types, rows, 0);
		return witness == null ? null : '[${witness.join(", ")}]';
	}

	static function missing(session:TypingSession, bodyTyper:BodyTyping, types:Array<CompilerType>,
			rows:Array<Array<TypedSwitchArrayElement>>, column:Int):Null<Array<String>> {
		if (column == types.length)
			return rows.length > 0 ? null : [];
		var type = types[column],
			values = finiteValues(session, bodyTyper, type),
			wildcards = [for (row in rows) if (row[column].isCatchAll) row];
		if (values == null || wildcards.length == rows.length) {
			var rest = missing(session, bodyTyper, types, wildcards, column + 1);
			return rest == null ? null : ["_"].concat(rest);
		}
		for (value in values) {
			var full = [
				for (row in rows)
					if (row[column].isCatchAll || row[column].predicates.length == 0
					&& matches(bodyTyper, row[column], value))
					row
			],
				rest = missing(session, bodyTyper, types, full, column + 1);
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
			case TNullableWrap(inner), TCast(inner), TAbiCast(inner): valueKey(bodyTyper, inner);
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
