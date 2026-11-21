package compiler.types.analysis;

import compiler.core.Source.SourceSpan;
import compiler.syntax.Ast.AstArgument;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstStatement;
import compiler.syntax.Ast.AstSwitchExpressionCase;
import compiler.syntax.Ast.AstType;

/** A local inline function's body as the value of an expression: its statements, then its result. */
typedef InlineBody = {
	final statements:Array<AstStatement>;
	final result:AstExpression;
}

/**
 * A local `inline function`, as in Haxe, is no value: each call is replaced by its body, which runs where the call is, and no
 * closure is made. `BindingWalker` resolves the body at each call, with the names it had where it was declared, and the typer
 * types it there (`CallResolver.typeInlineCall`).
 *
 * The body becomes an expression the way Haxe's inliner makes it one: a final `return` gives the result, and an `if` whose
 * branch returns takes the statements after it as its other branch. A function this cannot rewrite (a `return` in a loop or a
 * `try`), or with an optional parameter, stays a local function that is called through its closure, which behaves the same;
 * so does one called in a lambda that also reads another local named as one its body reads (`BodyResolution.callsThroughClosure`).
 */
class LocalInlineFunctions {
	/** Whether the lambda a local function is initialized with is inline and is replaced by its body at each call. */
	public static function expands(lambda:AstExpression):Bool
		return switch lambda {
			case Lambda(arguments, body, _, span, true): plainArguments(arguments) && inlineBody(body, span) != null;
			default: false;
		};

	/** `body` as an expression's statements and result, or null when a `return` in it cannot become the result. */
	public static function inlineBody(body:Array<AstStatement>, span:SourceSpan):Null<InlineBody>
		return tail(body, AstScan.returnsValue(body), new SourceSpan(span.file, span.end, span.end));

	/**
	 * The call of the local inline function with `arguments`, `body` and declared result `result` (null when inferred) with
	 * `values`: a block declaring each parameter with its value, in order, then the body. The parameters are declared at their
	 * own spans, which is where `BindingWalker` declared them, so the body reads them as it was resolved to.
	 */
	public static function call(arguments:Array<AstArgument>, body:Array<AstStatement>, result:Null<AstType>,
			values:Array<AstExpression>, span:SourceSpan):AstExpression {
		var inlined = inlineBody(body, span);
		if (inlined == null)
			throw new compiler.core.InternalError("A local inline function that does not expand was called inline",
				span);
		var statements:Array<AstStatement> = [];
		for (index in 0...arguments.length) {
			var argument = arguments[index];
			statements.push(VarDeclaration(argument.name, switch argument.type {
				case InferredType: null;
				default: argument.type;
			}, values[index], argument.span));
		}
		for (statement in inlined.statements)
			statements.push(statement);
		var value = inlined.result;
		if (result != null)
			switch value {
				case EmptyExpression(_), Unreachable(_):
				default: value = CheckType(value, result, compiler.syntax.Parser.expressionSpan(value));
			}
		return BlockExpression(statements, value, span);
	}

	/** No parameter is optional: a call passes every one, as the expansion needs. */
	static function plainArguments(arguments:Array<AstArgument>):Bool {
		for (argument in arguments)
			if (argument.optional == true || argument.defaultValue != null)
				return false;
		return true;
	}

	/**
	 * `statements` with their final `return` taken out as the result (`value`), or, for a function returning nothing, an empty
	 * result. Null when a `return` is anywhere else.
	 */
	static function tail(statements:Array<AstStatement>, value:Bool, end:SourceSpan):Null<InlineBody> {
		var kept:Array<AstStatement> = [];
		for (index in 0...statements.length) {
			var statement = statements[index], last = index == statements.length - 1;
			switch statement {
				case Return(expression, _) if (value && last):
					return {statements: kept, result: expression};
				case ReturnVoid(span) if (!value && last):
					return {statements: kept, result: EmptyExpression(span)};
				case Throw(_, span) if (last):
					kept.push(statement);
					return {statements: kept, result: value ? Unreachable(span) : EmptyExpression(span)};
				case If(test, yes, no, span) if (AstScan.returns(yes) || AstScan.returns(no)):
					// The statements after an `if` whose branch returns are the other branch.
					var rest = statements.slice(index + 1),
						whenTrue = last ? yes : no.length == 0 && exits(yes) ? yes : null,
						whenFalse = last ? no : no.length == 0 && exits(yes) ? rest : null;
					if (whenTrue == null || whenFalse == null)
						return null;
					var yesBody = tail(whenTrue, value, end), noBody = tail(whenFalse, value, end);
					if (yesBody == null || noBody == null)
						return null;
					if (value)
						return {
							statements: kept,
							result: Conditional(test, block(yesBody, span), block(noBody, span), span)
						};
					kept.push(If(test, statementsOf(yesBody, span), statementsOf(noBody, span), span));
					return {statements: kept, result: EmptyExpression(end)};
				case Switch(subject, cases, defaultBranch, hasDefault, span) if (last && AstScan.returns([statement])):
					if (value) {
						var arms:Array<AstSwitchExpressionCase> = [];
						for (entry in cases) {
							var arm = tail(entry.statements, true, end);
							if (arm == null)
								return null;
							arms.push({
								patterns: entry.patterns,
								guard: entry.guard,
								result: block(arm, entry.span),
								span: entry.span
							});
						}
						var fallback = hasDefault ? tail(defaultBranch, true, end) : null;
						if (hasDefault && fallback == null)
							return null;
						return {
							statements: kept,
							result: SwitchExpression(subject, arms, fallback == null ? null : block(fallback, span),
								span)
						};
					}
					var bodies = [];
					for (entry in cases) {
						var arm = tail(entry.statements, false, end);
						if (arm == null)
							return null;
						bodies.push({
							patterns: entry.patterns,
							guard: entry.guard,
							statements: statementsOf(arm, entry.span),
							span: entry.span
						});
					}
					var fallback = tail(defaultBranch, false, end);
					if (fallback == null)
						return null;
					kept.push(Switch(subject, bodies, statementsOf(fallback, span), hasDefault, span));
					return {statements: kept, result: EmptyExpression(end)};
				default:
					if (AstScan.returns([statement]))
						return null;
					kept.push(statement);
			}
		}
		// Falling off the end returns nothing, which only a function returning nothing may do.
		return value ? null : {statements: kept, result: EmptyExpression(end)};
	}

	/** Whether control never leaves the end of `statements`: the last one returns or throws. */
	static function exits(statements:Array<AstStatement>):Bool
		return statements.length > 0 && switch statements[statements.length - 1] {
			case Return(_, _), ReturnVoid(_), Throw(_, _): true;
			case If(_, yes, no, _): exits(yes) && exits(no);
			default: false;
		};

	static function block(body:InlineBody, span:SourceSpan):AstExpression
		return BlockExpression(body.statements, body.result, span);

	/** A body returning nothing as statements; its result is empty. */
	static function statementsOf(body:InlineBody, span:SourceSpan):Array<AstStatement>
		return switch body.result {
			case EmptyExpression(_): body.statements;
			default: body.statements.concat([Expression(body.result, span)]);
		};
}
