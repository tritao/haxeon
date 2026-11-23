package compiler.types.typing;

import compiler.core.Diagnostic;
import compiler.core.Diagnostic.CompileError;
import compiler.core.Source.SourceSpan;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstStatement;
import compiler.syntax.Ast.AstSwitchCase;
import compiler.syntax.Ast.AstSwitchExpressionCase;
import compiler.syntax.Ast.TemporaryLocal;

/** A switch whose structure patterns were rewritten: `subject` is the tuple of the fields they read, `values` the cases' patterns. */
typedef StructureSwitch = {
	final subject:AstExpression;
	final values:Array<AstExpression>;

	/** The field path each element of the tuple reads ("" the subject itself, "a.b" `subject.a.b`), for E1021's message. */
	final columns:Array<String>;
}

/** A switch with structure patterns as the switches that match it: `statements` or `expression`, and the tuple's `columns`. */
typedef StructureRewrite<T> = {
	final rewritten:T;
	final columns:Array<String>;
}

/**
 * Haxe's structure patterns, `case {x: 1, y: y}:`, as the tuple switch Haxe's matcher makes of them: each field a case names is
 * a column, read from the subject (`[subject.x, subject.y]`), and each case the tuple pattern of its fields, `_` for a field it
 * leaves out. A nested structure pattern adds the columns of its fields (`{a: {b: 1}}` reads `subject.a.b`); a capture of the
 * whole subject or of a field (`case p = {x: 0}:`, `case {a: inner = {b: 1}}:`) is a column of its own, which it binds. The
 * tuple switch then gives each field pattern its own type and the exhaustiveness rules of a tuple (`TupleSwitch`): a field of an
 * enum type is covered constructor by constructor, an Int field only by `_`.
 *
 * `case null:` beside them matches a null subject, which has no fields to read: the switch first tests the subject for null and
 * runs the first case that matches null (`null`, `_` or a name), and otherwise matches the fields of the cases that are not
 * `null`.
 */
class StructurePatterns {
	/** Whether a case of the switch is a structure pattern: an object literal, whole or captured. */
	public static function present(values:Array<AstExpression>):Bool {
		for (value in values)
			if (isStructure(value))
				return true;
		return false;
	}

	static function isStructure(value:AstExpression):Bool
		return switch value {
			case ObjectLiteral(_, _): true;
			case Capture(_, inner, _): isStructure(inner);
			default: false;
		};

	/** The switch statement of `subject` with `cases`, some of them structure patterns, as the switches that match it. */
	public static function rewriteStatement(subject:AstExpression, cases:Array<AstSwitchCase>,
			defaultBranch:Array<AstStatement>, hasDefault:Bool, span:SourceSpan):StructureRewrite<Array<AstStatement>> {
		var held = hold(subject, span),
			fieldCases = [for (switchCase in cases)
				if (!isNullPattern(compiler.syntax.SwitchCases.only(switchCase.patterns))) switchCase],
			tuple = rewrite(held.value,
				[for (switchCase in fieldCases) compiler.syntax.SwitchCases.only(switchCase.patterns)], span);
		var fieldSwitch = Switch(tuple.subject, [for (index in 0...fieldCases.length)
			{
				patterns:[tuple.values[index]],
					guard:fieldCases[index].guard,
					statements:fieldCases[index].statements,
					span:fieldCases[index].span
			}], defaultBranch, hasDefault, span),
				statements:Array<AstStatement> = held.temporary == null ? [] : [held.temporary];
		if (fieldCases.length == cases.length)
			statements.push(fieldSwitch);
		else {
			var nullCases:Array<AstSwitchCase> = [], covered = false;
			for (switchCase in cases)
				if (matchesNull(compiler.syntax.SwitchCases.only(switchCase.patterns))) {
					covered = switchCase.guard == null;
					nullCases.push({
						patterns: [covered ? openNull(compiler.syntax.SwitchCases.only(switchCase.patterns))
							: compiler.syntax.SwitchCases.only(switchCase.patterns)],
						guard: switchCase.guard,
						statements: switchCase.statements,
						span: switchCase.span
					});
					if (covered)
						break;
				}
			// A null no case matches reaches the default, or else reads the fields it has not, as Haxe's matcher does.
			var nullSwitch = Switch(held.value, nullCases, covered ? [] : hasDefault ? defaultBranch : [fieldSwitch],
				!covered, nullSpan(compiler.syntax.SwitchCases.patterns(cases)));
			statements.push(If(Equal(held.value, NullLiteral(span), span), [nullSwitch], [fieldSwitch], span));
		}
		return {rewritten: statements, columns: tuple.columns};
	}

	/** The switch expression of `subject` with `cases`, some of them structure patterns, as the switches that match it. */
	public static function rewriteExpression(subject:AstExpression, cases:Array<AstSwitchExpressionCase>,
			fallback:Null<AstExpression>, span:SourceSpan):StructureRewrite<AstExpression> {
		var held = hold(subject, span),
			fieldCases = [for (switchCase in cases)
				if (!isNullPattern(compiler.syntax.SwitchCases.only(switchCase.patterns))) switchCase],
			tuple = rewrite(held.value,
				[for (switchCase in fieldCases) compiler.syntax.SwitchCases.only(switchCase.patterns)], span);
		var fieldSwitch = SwitchExpression(tuple.subject, [for (index in 0...fieldCases.length)
			{
				patterns:[tuple.values[index]],
					guard:fieldCases[index].guard,
					result:fieldCases[index].result,
					span:fieldCases[index].span
			}], fallback, span),
				result = fieldSwitch;
		if (fieldCases.length != cases.length) {
			var nullCases:Array<AstSwitchExpressionCase> = [], covered = false;
			for (switchCase in cases)
				if (matchesNull(compiler.syntax.SwitchCases.only(switchCase.patterns))) {
					covered = switchCase.guard == null;
					nullCases.push({
						patterns: [covered ? openNull(compiler.syntax.SwitchCases.only(switchCase.patterns))
							: compiler.syntax.SwitchCases.only(switchCase.patterns)],
						guard: switchCase.guard,
						result: switchCase.result,
						span: switchCase.span
					});
					if (covered)
						break;
				}
			// A null no case matches reaches the default, or else reads the fields it has not, as Haxe's matcher does.
			var nullSwitch = SwitchExpression(held.value, nullCases,
				covered ? null : fallback == null ? fieldSwitch : fallback,
				nullSpan(compiler.syntax.SwitchCases.expressionPatterns(cases)));
			result = Conditional(Equal(held.value, NullLiteral(span), span), nullSwitch, fieldSwitch, span);
		}
		return {
			rewritten: held.temporary == null ? result : BlockExpression([held.temporary], result, span),
			columns: tuple.columns
		};
	}

	/** `case null:`, or a capture of it. */
	static function isNullPattern(value:AstExpression):Bool
		return switch value {
			case NullLiteral(_): true;
			case Capture(_, inner, _): isNullPattern(inner);
			default: false;
		};

	/** Whether a case matches a null subject: `null`, `_`, a name, or a capture of one of them. */
	static function matchesNull(value:AstExpression):Bool
		return switch value {
			case NullLiteral(_): true;
			case Variable(name, span): name == "_"
				|| compiler.syntax.AstPredicates.patternCaptureName(name, span) != null;
			case Capture(_, inner, _): matchesNull(inner);
			default: false;
		};

	/** A case that matches a null subject as `_`, which a subject known to be null always matches. */
	static function openNull(value:AstExpression):AstExpression
		return switch value {
			case NullLiteral(span): Variable("_", span);
			case Capture(name, inner, span): Capture(name, openNull(inner), span);
			default: value;
		};

	/** The span of the switch that matches a null subject: the first `case null:`'s, which names what lowering keeps for it. */
	static function nullSpan(values:Array<AstExpression>):SourceSpan {
		for (value in values)
			if (isNullPattern(value))
				return patternSpan(value);
		throw new compiler.core.InternalError("A structure switch lost its null case");
	}

	/** The subject as a variable: itself when it is a local, else one the rewritten switch declares. */
	static function hold(subject:AstExpression, span:SourceSpan):{temporary:Null<AstStatement>,
		value:AstExpression} return switch subject {
			case Variable(name, _) if (name != "this"):
				{temporary: null, value: subject};
			case TemporaryVariable(_, _), DeclaredVariable(_, _, _):
				{temporary: null, value: subject};
			default:
				var held = new TemporaryLocal("__haxeon_structure" + span.start);
				{
					temporary:TemporaryDeclaration(held, null, subject, span), value:TemporaryVariable(held, span)
				};
		};

	/** The tuple switch of a switch over `holder` (a variable) with the case patterns `values`, some of them structure patterns. */
	static function rewrite(holder:AstExpression, values:Array<AstExpression>, span:SourceSpan):StructureSwitch {
		var columns:Array<String> = [],
			rows:Array<Map<String, AstExpression>> = [],
			fieldSpans:Map<String, SourceSpan> = [];
		for (value in values) {
			var row:Map<String, AstExpression> = [];
			collect(value, "", row, columns, true, fieldSpans);
			rows.push(row);
		}
		// Cases that name no field still match through a tuple: one of the subject itself.
		if (columns.length == 0)
			columns.push("");
		var elements = [for (column in columns) read(holder, column, fieldSpans, span)];
		return {
			subject: ArrayLiteral(elements, span),
			values: [
				for (index in 0...values.length)
					ArrayLiteral([
						for (column in columns)
							rows[index].exists(column) ? rows[index].get(column) : Variable("_",
							patternSpan(values[index]))
					], patternSpan(values[index]))
			],
			columns: columns
		};
	}

	/**
	 * The column patterns of `pattern`, matched at the field path `path` ("" for the subject, "a.b" for `subject.a.b`). At the
	 * subject itself only a structure, `_` or a capture can stand: the subject is matched field by field.
	 */
	static function collect(pattern:AstExpression, path:String, row:Map<String, AstExpression>, columns:Array<String>,
			root:Bool, fieldSpans:Map<String, SourceSpan>):Void {
		switch pattern {
			case ObjectLiteral(fields, _):
				for (field in fields) {
					var fieldPath = path == "" ? field.name : path + "." + field.name;
					if (row.exists(fieldPath))
						throw new CompileError(new Diagnostic("E1019",
							'Duplicate field "${field.name}" in structure pattern',
							field.span));
					if (!fieldSpans.exists(fieldPath))
						fieldSpans.set(fieldPath, field.span);
					collect(field.value, fieldPath, row, columns, false, fieldSpans);
				}
			case Capture(name, inner, span) if (isStructure(inner)):
				set(path, Capture(name, Variable("_", span), span), row, columns);
				collect(inner, path, row, columns, root, fieldSpans);
			case Variable("_", _):
			case Variable(_, _):
				set(path, pattern, row, columns);
			default:
				if (root)
					throw new CompileError(new Diagnostic("E1019",
						"A switch with structure patterns matches structures, captures, _ or null in each case",
						patternSpan(pattern)));
				set(path, pattern, row, columns);
		}
	}

	static function set(path:String, pattern:AstExpression, row:Map<String, AstExpression>,
			columns:Array<String>):Void {
		row.set(path, pattern);
		if (columns.indexOf(path) < 0)
			columns.push(path);
	}

	/** The read of the field at `path`, at the pattern's field for an error there (`{missing: 1}` names no field). */
	static function read(holder:AstExpression, path:String, fieldSpans:Map<String, SourceSpan>,
			span:SourceSpan):AstExpression {
		var value = holder, prefix = "";
		if (path != "")
			for (name in path.split(".")) {
				prefix = prefix == "" ? name : prefix + "." + name;
				var fieldSpan = fieldSpans.get(prefix);
				value = Member(value, name, fieldSpan == null ? span : fieldSpan);
			}
		return value;
	}

	static function patternSpan(pattern:AstExpression):SourceSpan
		return compiler.syntax.Parser.expressionSpan(pattern);
}
