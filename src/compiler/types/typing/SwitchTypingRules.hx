package compiler.types.typing;

import compiler.syntax.Ast.AstExpression;
import compiler.types.Type.CompilerType;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedSwitchArrayPattern;
import compiler.types.TypedAst.TypedSwitchBinding;
import compiler.types.TypedAst.TypedSwitchCoverageCase;
import compiler.types.TypedAst.TypedSwitchPredicate;
import compiler.types.analysis.Scope;

typedef SwitchArrayPatternCallback = (AstExpression, CompilerType, Scope) -> Null<TypedSwitchArrayPattern>;
typedef SwitchArrayPatternKeyCallback = TypedSwitchArrayPattern->Null<String>;

typedef SwitchPattern = {
	value:TypedExpression,
	enumName:String,
	index:Int,
	bindings:Array<TypedSwitchBinding>,
	predicates:Array<TypedSwitchPredicate>
};

/**
 * The switch rules BodyTyper implements, shared by statement switches (StatementTyper) and switch expressions (ExpressionTyper).
 * Both receive the same object, so this is the one declaration of its shape: two copies drifted once, which stock Haxe accepted and
 * Haxeon, which does not take a structure with fields its type does not list, rejected.
 */
typedef SwitchTypingRules = {
	subjectBinding:(AstExpression, CompilerType, Scope) -> Null<String>,
	catchAll:AstExpression->Bool,
	enumPattern:(AstExpression, CompilerType, Scope) -> Null<SwitchPattern>,
	arrayPattern:SwitchArrayPatternCallback,
	arrayPatternKey:SwitchArrayPatternKeyCallback,
	caseKey:(TypedExpression, Array<TypedSwitchPredicate>) -> Null<String>,
	enumCaseCovered:(CompilerType, Int, Array<TypedSwitchCoverageCase>) -> Bool,
	enumLiteral:TypedExpression->Null<{name:String, index:Int}>,
	isEnum:CompilerType->Bool,
	isNullableEnum:CompilerType->Bool,
	enumName:CompilerType->Null<String>,

	/** The values of a closed enum abstract keyed as switch cases are, or null when the subject is not one. */
	closedEnumAbstractValues:CompilerType->Null<Array<{name:String, key:String}>>
};
