package compiler.types.typing;

import compiler.core.Source.SourceSpan;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstStatement;
import compiler.syntax.Ast.AstSwitchCase;
import compiler.syntax.Ast.AstSwitchExpressionCase;

/**
 * Haxe's extractor patterns, `case expression => pattern:`, as the nested switches Haxe's matcher makes of them: the cases before
 * the first extractor match the subject as they are; that extractor's expression, with `_` the subject, is evaluated once, when
 * no earlier case matched, for it and the extractor cases right after it that share its expression (Haxe evaluates such a
 * shared extractor once), whose patterns match its value; the cases after them match the subject again when none of those
 * did. So `case _.length => 3:` matches an array of three, and `case parse(_) => Some(value):` binds what `parse` returns.
 *
 * The expression reads the subject as `_`: it is evaluated in a block that declares `_` as the subject, held in a variable when
 * it is not one already. `name = expression => pattern` binds the subject to `name` in the case's guard and body.
 */
class ExtractorPatterns {
	/** Whether a case of the switch is an extractor, whole or captured. */
	public static function present(values:Array<AstExpression>):Bool {
		for (value in values)
			if (extractorOf(value) != null)
				return true;
		return false;
	}

	/** The switch statement of `subject` with `cases`, its extractor cases matched as nested switches. */
	public static function rewriteStatement(subject:AstExpression, cases:Array<AstSwitchCase>,
			defaultBranch:Array<AstStatement>, hasDefault:Bool, span:SourceSpan):Array<AstStatement> {
		var held = hold(subject, span), first = firstExtractor([for (switchCase in cases) switchCase.value]);
		var group = groupEnd([for (switchCase in cases) switchCase.value], first),
			extractor = requiredExtractor(cases[first].value),
			inner:Array<AstSwitchCase> = [],
			open = true;
		for (index in first...group) {
			var switchCase = cases[index], parts = requiredExtractor(switchCase.value);
			inner.push({
				value: parts.pattern,
				guard: bound(parts.name, held.value, switchCase.guard, span),
				statements: parts.name == null ? switchCase.statements : [
					VarDeclaration(parts.name, null, held.value, span)
				].concat(switchCase.statements),
				span: switchCase.span
			});
			if (switchCase.guard == null && isIrrefutable(parts.pattern)) {
				open = false;
				break;
			}
		}
		var rest = cases.slice(group),
			innerDefault:Array<AstStatement> = [],
			innerHasDefault = false;
		if (open && rest.length > 0) {
			innerDefault = [Switch(held.value, rest, defaultBranch, hasDefault, patternSpan(rest[0].value))];
			innerHasDefault = true;
		} else if (open && hasDefault) {
			innerDefault = defaultBranch;
			innerHasDefault = true;
		}
		// Each switch has a span of its own, which names what lowering keeps for it.
		var matched = Switch(evaluated(extractor.expression, held.value, span), inner, innerDefault, innerHasDefault,
			patternSpan(cases[first].value)),
			statements:Array<AstStatement> = held.declaration == null ? [] : [held.declaration];
		statements.push(first == 0 ? matched : Switch(held.value, cases.slice(0, first), [matched], true, span));
		return statements;
	}

	/** The switch expression of `subject` with `cases`, its extractor cases matched as nested switches. */
	public static function rewriteExpression(subject:AstExpression, cases:Array<AstSwitchExpressionCase>,
			fallback:Null<AstExpression>, span:SourceSpan):AstExpression {
		var held = hold(subject, span), first = firstExtractor([for (switchCase in cases) switchCase.value]);
		var group = groupEnd([for (switchCase in cases) switchCase.value], first),
			extractor = requiredExtractor(cases[first].value),
			inner:Array<AstSwitchExpressionCase> = [],
			open = true;
		for (index in first...group) {
			var switchCase = cases[index], parts = requiredExtractor(switchCase.value);
			inner.push({
				value: parts.pattern,
				guard: bound(parts.name, held.value, switchCase.guard, span),
				result: parts.name == null ? switchCase.result : BlockExpression([
					VarDeclaration(parts.name, null, held.value, span)
				], switchCase.result, span),
				span: switchCase.span
			});
			if (switchCase.guard == null && isIrrefutable(parts.pattern)) {
				open = false;
				break;
			}
		}
		var rest = cases.slice(group),
			innerFallback:Null<AstExpression> = null;
		if (open && rest.length > 0)
			innerFallback = SwitchExpression(held.value, rest, fallback, patternSpan(rest[0].value));
		else if (open)
			innerFallback = fallback;
		// Each switch has a span of its own, which names what lowering keeps for it.
		var matched = SwitchExpression(evaluated(extractor.expression, held.value, span), inner, innerFallback,
			patternSpan(cases[first].value)),
			result = first == 0 ? matched : SwitchExpression(held.value, cases.slice(0, first), matched, span);
		return held.declaration == null ? result : BlockExpression([held.declaration], result, span);
	}

	/** The subject as a variable: itself when it is a local, else one the rewritten switch declares. */
	static function hold(subject:AstExpression, span:SourceSpan):{declaration:Null<AstStatement>,
		value:AstExpression} return switch subject {
			case Variable(name, _) if (name != "this" && name != "_"):
				{declaration: null, value: subject};
			default:
				var name = "__haxeon_extracted" + span.start;
				{
					declaration:VarDeclaration(name, null, subject, span), value:Variable(name, span)
				};
		};

	/** `expression` with `_` the subject: a block that declares `_` for it. */
	static function evaluated(expression:AstExpression, subject:AstExpression, span:SourceSpan):AstExpression
		return BlockExpression([VarDeclaration("_", null, subject, span)], expression, span);

	/** A guard that reads the subject's capture `name`: in a block that binds it, as the body is. */
	static function bound(name:Null<String>, subject:AstExpression, guard:Null<AstExpression>,
			span:SourceSpan):Null<AstExpression>
		return name == null
			|| guard == null ? guard : BlockExpression([VarDeclaration(name, null, subject, span)], guard,
			span);

	static function firstExtractor(values:Array<AstExpression>):Int {
		for (index in 0...values.length)
			if (extractorOf(values[index]) != null)
				return index;
		return -1;
	}

	/** The end of the run of extractor cases from `first` whose expressions read alike, which Haxe evaluates once. */
	static function groupEnd(values:Array<AstExpression>, first:Int):Int {
		var source = sourceText(requiredExtractor(values[first]).expression), end = first + 1;
		while (end < values.length) {
			var next = extractorOf(values[end]);
			if (next == null || sourceText(next.expression) != source)
				break;
			end++;
		}
		return end;
	}

	static function patternSpan(pattern:AstExpression):SourceSpan
		return compiler.syntax.Parser.expressionSpan(pattern);

	static function sourceText(expression:AstExpression):String {
		var span = compiler.syntax.Parser.expressionSpan(expression);
		return span.file.slice(span.start, span.end);
	}

	/** A case's extractor: its expression and pattern, and the name that captures the subject (`name = expression => pattern`). */
	static function extractorOf(value:AstExpression):Null<{
		name:Null<String>,
		expression:AstExpression,
		pattern:AstExpression
	}>
		return switch value {
			case Extractor(expression, pattern, _): {name: null, expression: expression, pattern: pattern};
			case Capture(name, Extractor(expression, pattern, _), _):
				{name: name, expression: expression, pattern: pattern};
			default: null;
		};

	/** The extractor of a case known to be one. */
	static function requiredExtractor(value:AstExpression):{
		name:Null<String>,
		expression:AstExpression,
		pattern:AstExpression
	} {
		var found = extractorOf(value);
		if (found == null)
			throw new compiler.core.InternalError("An extractor case lost its extractor");
		return found;
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
