package compiler.types.typing;

import compiler.core.Diagnostic;
import compiler.core.Diagnostic.CompileError;
import compiler.core.Source.SourceSpan;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstObjectField;
import compiler.syntax.Ast.AstStatement;
import compiler.syntax.Ast.AstSwitchCase;
import compiler.syntax.Ast.AstSwitchExpressionCase;
import compiler.syntax.Ast.TemporaryLocal;

/** An extractor, `expression => pattern`, and the name that captures the value it reads (`name = expression => pattern`). */
typedef ExtractorParts = {
	final name:Null<String>;
	final expression:AstExpression;
	final pattern:AstExpression;
}

/**
 * The first step of a switch with extractors: the cases `first` to `end` (exclusive) share one extractor, evaluated once on
 * `extracted` (the subject, or the part of it a nested extractor reads), and match its value against their `inner` patterns. A
 * nested extractor is matched under `outer`, the case's pattern with the extractor replaced by the variable that holds the part.
 */
typedef ExtractorStep = {
	final declarations:Array<AstStatement>;
	final subject:AstExpression;
	final first:Int;
	final end:Int;
	final expression:AstExpression;
	final extracted:AstExpression;
	final outer:Null<AstExpression>;
	final inner:Array<ExtractorParts>;
	final span:SourceSpan;
}

/**
 * Haxe's extractor patterns, `case expression => pattern:`, as the nested switches Haxe's matcher makes of them.
 *
 * A whole case: the cases before the first extractor match the subject as they are; that extractor's expression, with `_` the
 * subject, is evaluated once, when no earlier case matched, for it and the extractor cases right after it that share its
 * expression (Haxe evaluates such a shared extractor once), whose patterns match its value; the cases after them match the subject
 * again when none of those did. So `case _.length => 3:` matches an array of three, and `case parse(_) => Some(value):` binds what
 * `parse` returns.
 *
 * A nested extractor (`case Some(_.length => 3):`, `case [_ * 2 => 4, _]:`, `case {name: _.length => 3}:`) reads the part of the
 * subject it stands for: the case matches the subject with a variable in its place (`Some(part)`), and then the value of the
 * expression, with `_` that part, against the extractor's pattern. Consecutive cases that differ only in that pattern share the
 * evaluation, as Haxe's matcher shares it. When the pattern can fail, the cases after the run match the subject again; when it
 * cannot (`_`, a name), the case covers what its outer pattern covers, as in Haxe. A case with several nested extractors is
 * matched from its last one out, so they are evaluated in source order, each once the ones before it matched.
 *
 * The expression reads the subject as `_`: it is evaluated in a block that declares `_` as the subject, held in a variable when
 * it is not one already (a tuple's elements each in its own). `name = expression => pattern` binds what it reads to `name` in the
 * case's guard and body.
 */
class ExtractorPatterns {
	/** Whether a case of the switch has an extractor, as the whole case or in its pattern. */
	public static function present(values:Array<AstExpression>):Bool {
		for (value in values)
			if (contains(value))
				return true;
		return false;
	}

	/** The spans of the names that capture what an extractor reads (`name = expression => pattern`), whole or nested. */
	public static function captures(values:Array<AstExpression>):Array<SourceSpan> {
		var found:Array<SourceSpan> = [];
		for (value in values)
			collectCaptures(value, found);
		return found;
	}

	/** The switch statement of `subject` with `cases`, its first run of extractor cases matched as nested switches. */
	public static function rewriteStatement(subject:AstExpression, cases:Array<AstSwitchCase>,
			defaultBranch:Array<AstStatement>, hasDefault:Bool, span:SourceSpan):Array<AstStatement> {
		var step = plan(subject, compiler.syntax.SwitchCases.patterns(cases), span),
			inner:Array<AstSwitchCase> = [],
			open = true;
		for (index in step.first...step.end) {
			var switchCase = cases[index], parts = step.inner[index - step.first];
			inner.push({
				patterns: [parts.pattern],
				guard: bound(parts.name, step.extracted, switchCase.guard, span),
				statements: parts.name == null ? switchCase.statements : [
					VarDeclaration(parts.name, null, step.extracted, span)
				].concat(switchCase.statements),
				span: switchCase.span
			});
			if (switchCase.guard == null && isIrrefutable(parts.pattern)) {
				open = false;
				break;
			}
		}
		var rest = cases.slice(step.end),
			// What runs when the run's patterns did not match: the cases after it, else the default.
			after:Array<AstStatement> = rest.length > 0 ? [
				Switch(step.subject, rest, defaultBranch, hasDefault,
					patternSpan(compiler.syntax.SwitchCases.only(rest[0].patterns)))
			] : defaultBranch,
			hasAfter = rest.length > 0 || hasDefault;
		// Each switch has a span of its own, which names what lowering keeps for it.
		var matched = Switch(evaluated(step.expression, step.extracted, span), inner, open ? after : [],
			open && hasAfter, step.span),
			before = cases.slice(0, step.first),
			statements = step.declarations.copy();
		if (step.outer == null)
			statements.push(step.first == 0 ? matched : Switch(step.subject, before, [matched], true, span));
		else {
			var outer:AstSwitchCase = {
				patterns: [step.outer],
				guard: null,
				statements: [matched],
				span: cases[step.first].span
			};
			// A run that can fail matches the cases after it again; one that cannot leaves them to the outer switch.
			statements.push(open ? Switch(step.subject, before.concat([outer]), after, hasAfter,
				span) : Switch(step.subject, before.concat([outer]).concat(rest), defaultBranch, hasDefault, span));
		}
		return statements;
	}

	/** The switch expression of `subject` with `cases`, its first run of extractor cases matched as nested switches. */
	public static function rewriteExpression(subject:AstExpression, cases:Array<AstSwitchExpressionCase>,
			fallback:Null<AstExpression>, span:SourceSpan):AstExpression {
		var step = plan(subject, compiler.syntax.SwitchCases.expressionPatterns(cases), span),
			inner:Array<AstSwitchExpressionCase> = [],
			open = true;
		for (index in step.first...step.end) {
			var switchCase = cases[index], parts = step.inner[index - step.first];
			inner.push({
				patterns: [parts.pattern],
				guard: bound(parts.name, step.extracted, switchCase.guard, span),
				result: parts.name == null ? switchCase.result : BlockExpression([
					VarDeclaration(parts.name, null, step.extracted, span)
				], switchCase.result, span),
				span: switchCase.span
			});
			if (switchCase.guard == null && isIrrefutable(parts.pattern)) {
				open = false;
				break;
			}
		}
		var rest = cases.slice(step.end),
			// What the switch is when the run's patterns did not match: the cases after it, else the default.
			after = rest.length > 0 ? SwitchExpression(step.subject, rest, fallback,
				patternSpan(compiler.syntax.SwitchCases.only(rest[0].patterns))) : fallback;
		// Each switch has a span of its own, which names what lowering keeps for it.
		var matched = SwitchExpression(evaluated(step.expression, step.extracted, span), inner, open ? after : null,
			step.span),
			before = cases.slice(0, step.first),
			result:AstExpression;
		if (step.outer == null)
			result = step.first == 0 ? matched : SwitchExpression(step.subject, before, matched, span);
		else {
			var outer:AstSwitchExpressionCase = {
				patterns: [step.outer],
				guard: null,
				result: matched,
				span: cases[step.first].span
			};
			// A run that can fail matches the cases after it again; one that cannot leaves them to the outer switch.
			result = open ? SwitchExpression(step.subject, before.concat([outer]), after,
				span) : SwitchExpression(step.subject, before.concat([outer]).concat(rest), fallback, span);
		}
		return step.declarations.length == 0 ? result : BlockExpression(step.declarations, result, span);
	}

	/** The first run of cases that share an extractor, whole or nested, in a switch over `subject`. */
	static function plan(subject:AstExpression, values:Array<AstExpression>, span:SourceSpan):ExtractorStep {
		rejectTupleExtractors(subject, values);
		var held = hold(subject, span), first = -1;
		for (index in 0...values.length)
			if (contains(values[index])) {
				first = index;
				break;
			}
		if (first < 0)
			throw new compiler.core.InternalError("A switch with extractors has no extractor case");
		var whole = extractorOf(values[first]);
		if (whole != null) {
			var source = sourceText(whole.expression), end = first + 1, inner = [whole];
			while (end < values.length) {
				var next = extractorOf(values[end]);
				if (next == null || sourceText(next.expression) != source)
					break;
				inner.push(next);
				end++;
			}
			return {
				declarations: held.declarations,
				subject: held.value,
				first: first,
				end: end,
				expression: whole.expression,
				extracted: held.value,
				outer: null,
				inner: inner,
				span: patternSpan(values[first])
			};
		}
		var hole = requiredHole(values[first]), key = holeKey(values[first], hole);
		// The part is the compiler's own binding, not a name the pattern writes (`.match` patterns may hold extractors).
		var part = Variable("__haxeon_part" + hole.span.start, SourceSpan.generated("extractor part")),
			end = first + 1,
			inner = [hole.parts];
		while (end < values.length && extractorOf(values[end]) == null) {
			var next = lastHole(values[end]);
			if (next == null || holeKey(values[end], next) != key)
				break;
			inner.push(next.parts);
			end++;
		}
		return {
			declarations: held.declarations,
			subject: held.value,
			first: first,
			end: end,
			expression: hole.parts.expression,
			extracted: part,
			outer: replaceHole(values[first], hole.span, part),
			inner: inner,
			span: hole.span
		};
	}

	/**
	 * In a tuple switch (`switch [a, b]`) `_` would be the tuple, which is no value, so Haxe rejects a whole-case extractor there;
	 * an element's extractor (`case [_.length => 2, _]:`) reads that element.
	 */
	static function rejectTupleExtractors(subject:AstExpression, values:Array<AstExpression>):Void {
		if (TupleSwitch.subjectElements(subject) == null)
			return;
		for (value in values)
			if (extractorOf(value) != null)
				throw new CompileError(new Diagnostic("E1019",
					"An extractor cannot read a whole tuple, which is no value: extract from an element (`case [_.length => 2, _]:`)",
					patternSpan(value)));
	}

	/** The subject as a variable: itself when it is a local, else one the rewritten switch declares; a tuple element by element. */
	static function hold(subject:AstExpression, span:SourceSpan):{declarations:Array<AstStatement>,
		value:AstExpression} {
		var elements = TupleSwitch.subjectElements(subject);
		if (elements != null) {
			var declarations:Array<AstStatement> = [],
				values:Array<AstExpression> = [];
			for (index in 0...elements.length) {
				var element = holdOne(elements[index], span, "__haxeon_extracted" + span.start + "_" + index);
				if (element.declaration != null)
					declarations.push(element.declaration);
				values.push(element.value);
			}
			return {declarations: declarations, value: ArrayLiteral(values, patternSpan(subject))};
		}
		var held = holdOne(subject, span, "__haxeon_extracted" + span.start);
		return {declarations: held.declaration == null ? [] : [held.declaration], value: held.value};
	}

	static function holdOne(value:AstExpression, span:SourceSpan, name:String):{
		declaration:Null<AstStatement>,
		value:AstExpression
	} return switch value {
		case Variable(local, _) if (local != "this" && local != "_"):
			{declaration: null, value: value};
		case TemporaryVariable(_, _), DeclaredVariable(_, _, _):
			{declaration: null, value: value};
		default:
			var held = new TemporaryLocal(name);
			{
				declaration:TemporaryDeclaration(held, null, value, span), value:TemporaryVariable(held, span)
			};
	};

	/** `expression` with `_` the value it reads: a block that declares `_` for it. */
	static function evaluated(expression:AstExpression, value:AstExpression, span:SourceSpan):AstExpression
		return BlockExpression([VarDeclaration("_", null, value, span)], expression, span);

	/** A guard that reads the capture `name`: in a block that binds it, as the body is. */
	static function bound(name:Null<String>, value:AstExpression, guard:Null<AstExpression>,
			span:SourceSpan):Null<AstExpression>
		return name == null
			|| guard == null ? guard : BlockExpression([VarDeclaration(name, null, value, span)], guard, span);

	static function patternSpan(pattern:AstExpression):SourceSpan
		return compiler.syntax.Parser.expressionSpan(pattern);

	static function sourceText(expression:AstExpression):String {
		var span = compiler.syntax.Parser.expressionSpan(expression);
		return span.file.slice(span.start, span.end);
	}

	/** An extractor written as `value` itself: its expression and pattern, and the name that captures what it reads. */
	static function extractorOf(value:AstExpression):Null<ExtractorParts>
		return switch value {
			case Extractor(expression, pattern, _): {name: null, expression: expression, pattern: pattern};
			case Capture(name, Extractor(expression, pattern, _), _):
				{name: name, expression: expression, pattern: pattern};
			default: null;
		};

	/** Whether `pattern` has an extractor, as itself or in a part it matches. */
	static function contains(pattern:AstExpression):Bool {
		if (extractorOf(pattern) != null)
			return true;
		for (part in parts(pattern))
			if (contains(part))
				return true;
		return false;
	}

	static function collectCaptures(pattern:AstExpression, found:Array<SourceSpan>):Void {
		switch pattern {
			case Capture(_, Extractor(_, inner, _), span):
				found.push(span);
				collectCaptures(inner, found);
			case Extractor(_, inner, _):
				collectCaptures(inner, found);
			default:
				for (part in parts(pattern))
					collectCaptures(part, found);
		}
	}

	/** The patterns `pattern` matches its parts against: a constructor's arguments, an array's elements, a structure's fields. */
	static function parts(pattern:AstExpression):Array<AstExpression>
		return switch pattern {
			case Call(_, arguments, _), MethodCall(_, _, arguments, _): arguments;
			case ArrayLiteral(values, _): values;
			case ObjectLiteral(fields, _): [for (field in fields) field.value];
			case Capture(_, inner, _): [inner];
			default: [];
		};

	/** The last extractor nested in `pattern` (not `pattern` itself), with the span it covers, or null when it has none. */
	static function lastHole(pattern:AstExpression):Null<{parts:ExtractorParts, span:SourceSpan}> {
		var children = parts(pattern), index = children.length;
		while (index > 0) {
			index--;
			var child = children[index], whole = extractorOf(child);
			if (whole != null)
				return {parts: whole, span: patternSpan(child)};
			var nested = lastHole(child);
			if (nested != null)
				return nested;
		}
		return null;
	}

	static function requiredHole(pattern:AstExpression):{parts:ExtractorParts, span:SourceSpan} {
		var hole = lastHole(pattern);
		if (hole == null)
			throw new compiler.core.InternalError("An extractor case lost its extractor");
		return hole;
	}

	/**
	 * What a nested extractor's case shares with the cases that may share its evaluation: the case's source around it and its
	 * expression. Only its pattern, and the name that captures what it reads, may differ.
	 */
	static function holeKey(pattern:AstExpression, hole:{parts:ExtractorParts, span:SourceSpan}):String {
		var span = patternSpan(pattern), text = span.file;
		return text.slice(span.start, hole.span.start) + "\u0001" + sourceText(hole.parts.expression) + "\u0001"
			+ text.slice(hole.span.end, span.end);
	}

	/** `pattern` with the part at `hole` (an extractor, or a capture of one) replaced by `replacement`. */
	static function replaceHole(pattern:AstExpression, hole:SourceSpan, replacement:AstExpression):AstExpression {
		var span = patternSpan(pattern);
		if (span.start == hole.start && span.end == hole.end && extractorOf(pattern) != null)
			return replacement;
		return switch pattern {
			case Call(name, arguments, callSpan):
				Call(name, [for (argument in arguments) replaceHole(argument, hole, replacement)], callSpan);
			case MethodCall(object, name, arguments, callSpan):
				MethodCall(object, name, [for (argument in arguments) replaceHole(argument, hole, replacement)],
					callSpan);
			case ArrayLiteral(values, arraySpan):
				ArrayLiteral([for (value in values) replaceHole(value, hole, replacement)], arraySpan);
			case ObjectLiteral(fields, objectSpan):
				var replaced:Array<AstObjectField> = [for (field in fields)
					{
						name:field.name, value:replaceHole(field.value, hole, replacement), span:field.span
					}];
				ObjectLiteral(replaced, objectSpan);
			case Capture(name, inner, captureSpan):
				Capture(name, replaceHole(inner, hole, replacement), captureSpan);
			default: pattern;
		};
	}

	/** A pattern every value matches: `_` or a lower-case name, after which no further case of the run can match. */
	static function isIrrefutable(pattern:AstExpression):Bool
		return switch pattern {
			case Variable(name, _):
				var first = name.charCodeAt(0);
				name == "_" || first != null && first >= "a".code && first <= "z".code;
			default: false;
		};
}
