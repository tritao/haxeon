package compiler.syntax;

import compiler.core.InternalError;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstSwitchCase;
import compiler.syntax.Ast.AstSwitchExpressionCase;

/** The patterns of switch cases, for the stages that look at each (docs/design/SWITCH_CASES.md). */
class SwitchCases {
	/** Every pattern of `cases`, in order. */
	public static function patterns(cases:Array<AstSwitchCase>):Array<AstExpression>
		return [for (switchCase in cases) for (pattern in switchCase.patterns) pattern];

	public static function expressionPatterns(cases:Array<AstSwitchExpressionCase>):Array<AstExpression>
		return [for (switchCase in cases) for (pattern in switchCase.patterns) pattern];

	/**
	 * A case per pattern, sharing the case's guard and statements, for the pattern rewrites that take one pattern per case
	 * (`ExtractorPatterns`, `StructurePatterns`); typing otherwise keeps a case's patterns together (`SwitchCaseTyper`).
	 */
	public static function perPattern(cases:Array<AstSwitchCase>):Array<AstSwitchCase>
		return [for (switchCase in cases)
			for (pattern in switchCase.patterns)
			{
				patterns:[pattern],
					guard:switchCase.guard,
					statements:switchCase.statements,
					span:switchCase.span
			}];

	public static function expressionPerPattern(cases:Array<AstSwitchExpressionCase>):Array<AstSwitchExpressionCase>
		return [for (switchCase in cases)
			for (pattern in switchCase.patterns)
			{
				patterns:[pattern],
					guard:switchCase.guard,
					result:switchCase.result,
					span:switchCase.span
			}];

	/** The one pattern of a case `perPattern` made. */
	public static function only(patterns:Array<AstExpression>):AstExpression {
		if (patterns.length != 1)
			throw new InternalError('A case split per pattern has ${patterns.length} patterns');
		return patterns[0];
	}
}
