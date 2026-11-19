package compiler.types.typing;

import compiler.core.Source.SourceSpan;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstStatement;
import compiler.types.analysis.AssignedDeclarations;
import compiler.types.analysis.AstScan;
import compiler.types.analysis.Scope;

/**
 * Flow facts hold where they are established, but a loop body runs again after itself: what one iteration changes is
 * gone by the next, and by the time the loop ends. Anything the body might change is therefore forgotten on entering
 * the loop, which is also where the facts leave it.
 */
class LoopFlow {
	/** The same for a comprehension, whose predicate and result expressions run once per item. */
	public static function enterExpressions(session:TypingSession, scope:Scope, expressions:Array<AstExpression>,
			span:SourceSpan,
			?loopVariables:Array<String>):Void
		enter(session, scope, [for (expression in expressions) Expression(expression, span)], loopVariables, span);

	/**
	 * The declarations the loop writes: from the body's resolution when it knows the loop at `loopSpan`, else by walking
	 * `statements`. With `CompileOptions.checkResolution` the two must agree on the `visible` declarations.
	 */
	static function assignedIn(session:TypingSession, statements:Array<AstStatement>, visible:Map<String, String>,
			loopSpan:Null<SourceSpan>):Map<String, Bool> {
		var resolution = session.currentContext.resolution;
		if (resolution == null || loopSpan == null)
			return AssignedDeclarations.within(statements, visible).declarations;
		var resolved = resolution.writesInLoop(loopSpan.start);
		if (resolved == null)
			return AssignedDeclarations.within(statements, visible).declarations;
		if (session.checkResolution) {
			var walked = AssignedDeclarations.within(statements, visible).declarations;
			for (name => declaration in visible)
				if (resolved.exists(declaration) != walked.exists(declaration))
					throw new compiler.core
						.InternalError('--check-resolution: the loop at ${loopSpan.start} in ${session.currentContext.name} ${walked.exists(declaration) ? "writes" : "does not write"} "$name" by its walk, but the resolution says otherwise',
						loopSpan);
		}
		return resolved;
	}

	/**
	 * Forget, in `scope`, every fact the loop made of `statements` could invalidate. `loopVariables` are the names the
	 * loop itself binds (a for-in's element), which are locals of the body even though the loop scope is not open yet.
	 */
	public static function enter(session:TypingSession, scope:Scope, statements:Array<AstStatement>,
			?loopVariables:Array<String>, ?loopSpan:SourceSpan):Void {
		var visible = scope.visibleDeclarations(), assigned = assignedIn(session, statements, visible, loopSpan);
		for (name => declaration in visible)
			if (assigned.exists(declaration))
				scope.invalidate(name);
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
		var stores = session.bodyStores(statements, locals, session.currentContext.lexicalOwner, privateMaps, arrays,
			maps);
		if (stores == null)
			session.invalidateUnknownCall(scope);
		else {
			// Stores forget only what the same store forgets in straight-line code, and also map-entry facts, which a
			// later iteration's store could falsify, including facts about array elements reached through aliases.
			for (field in stores.fields)
				scope.invalidateField(field);
			if (stores.indexed) {
				scope.invalidateExpressionNamespace("map-entry:");
				scope.invalidateExpressionNamespace("array-entry:");
			}
		}
		if (AstScan.mayRemoveMapEntries(statements))
			scope.invalidateExpressionNamespaceCompletely("map-entry:");
	}
}
