package compiler.types.typing;

import compiler.syntax.Ast.AstExpression;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedSwitchArrayPattern;
import compiler.types.TypedAst.TypedSwitchBinding;
import compiler.types.TypedAst.TypedSwitchPredicate;

typedef SwitchPattern = {
	value:TypedExpression,
	enumName:String,
	index:Int,
	bindings:Array<TypedSwitchBinding>,
	predicates:Array<TypedSwitchPredicate>
};

/** One case pattern, classified: the name it binds the subject to, whether it matches every value, and what it tests. */
typedef SwitchCasePattern = {
	/** The pattern left to match once a `name =` capture is removed. */
	value:AstExpression,

	subjectBinding:Null<String>,
	isCatchAll:Bool,
	arrayPattern:Null<TypedSwitchArrayPattern>,
	enumPattern:Null<SwitchPattern>
};
