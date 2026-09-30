package compiler.types.typing;

import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstStatement;
import compiler.Source.SourceSpan;
import compiler.types.analysis.AstScan;
import compiler.types.analysis.CaptureAnalysis;
import compiler.types.analysis.Scope;

/**
 * Flow facts hold where they are established, but a loop body runs again after itself: what one iteration changes is
 * gone by the next, and by the time the loop ends. Anything the body might change is therefore forgotten on entering
 * the loop, which is also where the facts leave it.
 */
class LoopFlow {
	/** The same for a comprehension, whose predicate and result expressions run once per item. */
	public static function enterExpressions(session:TypingSession, scope:Scope, expressions:Array<AstExpression>, span:SourceSpan):Void
		enter(session, scope, [for (expression in expressions) Expression(expression, span)]);

	/** Forget, in `scope`, every fact the loop made of `statements` could invalidate. */
	public static function enter(session:TypingSession, scope:Scope, statements:Array<AstStatement>):Void {
		var assigned:Map<String, Bool> = [];
		CaptureAnalysis.collectAssignedLocals(statements, assigned);
		for (name in assigned.keys()) {
			scope.invalidate(name);
			scope.invalidateExpressionsForLocal(name);
		}
		if (!session.bodyIsPure([], statements, scope.visibleLocalNames(), session.currentContext.lexicalOwner))
			scope.invalidateAllExpressions();
		if (AstScan.mayRemoveMapEntries(statements))
			scope.invalidateExpressionNamespaceCompletely("map-entry:");
	}
}
