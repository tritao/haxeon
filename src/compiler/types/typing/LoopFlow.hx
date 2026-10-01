package compiler.types.typing;

import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstStatement;
import compiler.Source.SourceSpan;
import compiler.types.analysis.AstScan;
import compiler.types.analysis.AssignedDeclarations;
import compiler.types.analysis.Scope;

/**
 * Flow facts hold where they are established, but a loop body runs again after itself: what one iteration changes is
 * gone by the next, and by the time the loop ends. Anything the body might change is therefore forgotten on entering
 * the loop, which is also where the facts leave it.
 */
class LoopFlow {
	/** The same for a comprehension, whose predicate and result expressions run once per item. */
	public static function enterExpressions(session:TypingSession, scope:Scope, expressions:Array<AstExpression>, span:SourceSpan,
			?loopVariables:Array<String>):Void
		enter(session, scope, [for (expression in expressions) Expression(expression, span)], loopVariables);

	/**
	 * Forget, in `scope`, every fact the loop made of `statements` could invalidate. `loopVariables` are the names the
	 * loop itself binds (a for-in's element), which are locals of the body even though the loop scope is not open yet.
	 */
	public static function enter(session:TypingSession, scope:Scope, statements:Array<AstStatement>, ?loopVariables:Array<String>):Void {
		var visible = scope.visibleDeclarations(),
			assigned = AssignedDeclarations.within(statements, visible).declarations;
		for (name => declaration in visible)
			if (assigned.exists(declaration)) {
				scope.invalidate(name);
				scope.invalidateExpressionsForLocal(name);
			}
		var locals = scope.visibleLocalNames(),
			privateMaps = scope.visiblePrivateMapNames(),
			arrays = scope.visibleArrayNames(),
			maps = scope.visiblePrimitiveMapNames();
		if (loopVariables != null)
			for (name in loopVariables)
				if (name != null) {
					locals.push(name);
					// The loop binding shadows an outer collection, even before its scope is opened.
					privateMaps.remove(name);
					arrays.remove(name);
					maps.remove(name);
				}
		var stores = session.bodyStores(statements, locals, session.currentContext.lexicalOwner, privateMaps, arrays, maps);
		if (stores == null)
			scope.invalidateAllExpressions();
		else {
			// Stores forget only what the same store forgets in straight-line code, and also map-entry facts, which a
			// later iteration's store could falsify. An array element carries no facts.
			for (field in stores.fields)
				scope.invalidateField(field);
			if (stores.indexed)
				scope.invalidateExpressionNamespace("map-entry:");
		}
		if (AstScan.mayRemoveMapEntries(statements))
			scope.invalidateExpressionNamespaceCompletely("map-entry:");
	}
}
