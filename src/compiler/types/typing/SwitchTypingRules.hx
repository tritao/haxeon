package compiler.types.typing;

import compiler.syntax.Ast.AstExpression;
import compiler.types.Type.CompilerType;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedSwitchArrayPattern;
import compiler.types.TypedAst.TypedSwitchBinding;
import compiler.types.TypedAst.TypedSwitchCoverageCase;
import compiler.types.TypedAst.TypedSwitchPredicate;
import compiler.types.analysis.Scope;

typedef SwitchArrayPatternKeyCallback = TypedSwitchArrayPattern->Null<String>;

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

/**
 * The switch rules BodyTyper implements, shared by statement switches (StatementTyper) and switch expressions (ExpressionTyper).
 * Both receive the same object, so this is the one declaration of its shape: two copies drifted once, which stock Haxe accepted and
 * Haxeon, which does not take a structure with fields its type does not list, rejected.
 */
typedef SwitchTypingRules = {
	casePattern:(AstExpression, CompilerType, Scope) -> SwitchCasePattern,

	/** The type constant cases compare as (the subject's, or the value type of a nullable one), or null when none apply. */
	constantType:CompilerType->Null<CompilerType>,

	arrayPatternKey:SwitchArrayPatternKeyCallback,
	caseKey:(TypedExpression, Array<TypedSwitchPredicate>) -> Null<String>,
	enumCaseCovered:(CompilerType, Int, Array<TypedSwitchCoverageCase>) -> Bool,
	enumLiteral:TypedExpression->Null<{name:String, index:Int}>,
	isEnum:CompilerType->Bool,
	isNullableEnum:CompilerType->Bool,
	enumName:CompilerType->Null<String>,

	/** The values of a closed enum abstract keyed as switch cases are (with `null` for a nullable one), or null when the subject is not one. */
	closedEnumAbstractValues:CompilerType->Null<Array<{name:String, key:String}>>
};
