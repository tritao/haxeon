package compiler.types.typing;

import compiler.types.TypedAst.TypedExpression;

typedef ResolvedInlineConstant = {
	/** Constants and enum abstract types read while resolving this value, including cached aliases. */
	final dependencies:Array<String>;
	final initializer:TypedExpression;
	final value:TypedExpression;
}

/**
 * Inline constants and enum abstract values resolved so far. Each is resolved once, from the declarations alone, the first
 * time a body reads it; the in-progress sets reject a constant defined through itself.
 */
class InlineConstantState {
	public final inlineConstants:Map<String, ResolvedInlineConstant> = [];
	public final inlineConstantsInProgress:Map<String, Bool> = [];
	public final enumAbstractConstants:Map<String, TypedExpression> = [];
	public final enumAbstractConstantsInProgress:Map<String, Bool> = [];

	/** The enum abstract whose value is being resolved, if any. */
	public var enumAbstractConstantOwner:Null<String> = null;

	public function new() {}

	/** Forgets the enum abstract values, which the next program may define differently. */
	public function clearEnumAbstractValues():Void {
		enumAbstractConstants.clear();
		enumAbstractConstantsInProgress.clear();
	}
}
