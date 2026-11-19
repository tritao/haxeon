package compiler.types.typing;

import compiler.core.Source.SourceSpan;
import compiler.semantic.SemanticProgram.SemanticMethodInfo;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstFunction;
import compiler.syntax.Ast.AstStatement;
import compiler.syntax.Ast.AstType;
import compiler.types.Type.CompilerType;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedFunction;
import compiler.types.TypedAst.TypedStatement;
import compiler.types.TypedAst.TypedSwitchArrayPattern;
import compiler.types.TypedAst.TypedSwitchCase;
import compiler.types.TypedAst.TypedSwitchCoverageCase;
import compiler.types.TypedAst.TypedSwitchPredicate;
import compiler.types.analysis.Scope;
import compiler.types.typing.SwitchTypingRules.SwitchCasePattern;

/**
 * What the body typer's collaborators (ExpressionTyper, CallResolver, StatementTyper, ClosureTyper, GenericInstantiation,
 * InlineConstantResolver) call back into. BodyTyper implements it and hands itself to each of them once.
 *
 * A default a method declares here only makes its parameter optional: the one that applies is BodyTyper's, which fills
 * it, as for any call through an interface (`DefaultArguments`).
 */
interface BodyTyping {
	// Expressions, statements and types.
	function typeExpression(expression:AstExpression, scope:Scope, ?expectedType:CompilerType,
			inferDynamicLambdaResult:Bool = false):TypedExpression;
	function coerce(value:TypedExpression, expected:CompilerType, context:String,
			code:String = "E1009"):TypedExpression;
	function typeStatements(statements:Array<AstStatement>, scope:Scope,
			result:Null<CompilerType>):Array<TypedStatement>;
	function lowerType(type:AstType, span:SourceSpan):CompilerType;
	function functionResultType(fn:AstFunction, span:SourceSpan):CompilerType;
	function dynamicIndex(index:TypedExpression):TypedExpression;
	function arrayElementType(type:CompilerType, span:SourceSpan):CompilerType;
	function exhaustiveSwitch(type:CompilerType, cases:Array<TypedSwitchCase>):Bool;

	// Expression forms BodyTyper owns.
	function typeVariableExpression(name:String, span:SourceSpan, scope:Scope,
			expectedType:Null<CompilerType>):TypedExpression;
	function typeMember(object:AstExpression, name:String, span:SourceSpan, scope:Scope):TypedExpression;
	function typeBlockExpression(statements:Array<AstStatement>, result:AstExpression, span:SourceSpan, scope:Scope,
			expectedType:Null<CompilerType>):TypedExpression;
	function typeMethodCall(object:AstExpression, name:String, arguments:Array<AstExpression>, span:SourceSpan,
			scope:Scope, ?expectedType:CompilerType):TypedExpression;
	function contextualExpressionType(expression:AstExpression, scope:Scope):Null<CompilerType>;

	// Functions, arguments and inline constants.
	function typeFunction(fn:AstFunction, ?owner:String, isStatic:Bool = false,
			?substitutions:Map<String, CompilerType>,
			?specializedName:String, ?abstractReceiver:CompilerType, ?physicalOwner:String,
			?ownerTypeArguments:Array<CompilerType>, ?inference:DeclarationTypeTable.FunctionInference,
			?elaboration:GenericElaboration):TypedFunction;
	function argumentTypesOf(fn:AstFunction, ?substitutions:Map<String, CompilerType>):Array<CompilerType>;
	function elaborateBoundary(value:TypedExpression, target:CompilerType):TypedExpression;
	function elaborateOperation(operation:compiler.types.TypedAst.ParameterOperation, arguments:Array<TypedExpression>,
			span:compiler.core.Source.SourceSpan):TypedExpression;
	function typeDefaultExpression(expression:AstExpression, expected:CompilerType,
			declarationName:String):TypedExpression;
	function posInfosExpression(span:SourceSpan):AstExpression;
	function typeInlineInitializer(expression:AstExpression, owner:String, name:String, expected:Null<CompilerType>,
			typeParameters:Array<String>):TypedExpression;

	// Members, fields and receivers.
	function findFieldType(type:CompilerType, name:String):Null<CompilerType>;
	function fieldType(type:CompilerType, name:String, span:SourceSpan):CompilerType;
	function typedMember(typedObject:TypedExpression, name:String, span:SourceSpan):TypedExpression;
	function typedMemberWithFlow(object:TypedExpression, name:String, span:SourceSpan, scope:Scope):TypedExpression;
	function resolveReceiver(name:String, span:SourceSpan, scope:Scope):Null<TypedExpression>;
	function lexicalMethod(name:String):Null<SemanticMethodInfo>;
	function findStaticFieldNullable(className:String, name:String):Null<{owner:String, type:CompilerType}>;
	function findStaticField(className:String, name:String, span:SourceSpan):{owner:String, type:CompilerType};
	function rejectInlineFieldMutation(owner:String, name:String, span:SourceSpan):Void;
	function propertySetterCall(object:TypedExpression, setter:String, value:TypedExpression,
			span:SourceSpan):TypedExpression;
	function accessorPropertyWrite(object:TypedExpression, name:String, expression:AstExpression, span:SourceSpan,
			scope:Scope, ?assigned:AssignedValue):Null<TypedExpression>;
	/** An assignment used as a value (`AssignmentValue`), with Haxe's value: see `StatementTyper.typeAssignmentValue`. */
	function typeAssignmentValue(assignment:AstStatement, span:SourceSpan, scope:Scope):TypedExpression;
	function implicitReceiver(span:SourceSpan, scope:Scope):TypedExpression;

	// Captured locals.
	function boundCell(name:String, scope:Scope):Null<String>;
	function bindCell(name:String, span:SourceSpan, scope:Scope, type:CompilerType):Void;

	// Switch rules, shared by statement switches and switch expressions.
	function switchCasePattern(value:AstExpression, expected:CompilerType, scope:Scope):SwitchCasePattern;
	function rejectMatchPatternVariable(span:SourceSpan):Void;
	function enterStructureSwitch(span:SourceSpan, columns:Array<String>):Void;
	function leaveStructureSwitch():Void;
	function structureSwitchColumns(span:SourceSpan):Null<Array<String>>;
	function switchTuplePattern(value:AstExpression, elementTypes:Array<CompilerType>, caseSpan:SourceSpan,
			scope:Scope):SwitchCasePattern;

	/** The type constant cases compare as (the subject's, or the value type of a nullable one), or null when none apply. */
	function switchConstantType(subject:CompilerType):Null<CompilerType>;

	function switchArrayPatternKey(pattern:TypedSwitchArrayPattern):Null<String>;
	function switchCaseKey(value:TypedExpression, predicates:Array<TypedSwitchPredicate>):Null<String>;

	/** While a case's pattern is typed, the names it binds, in order (`SwitchCaseTyper`); null otherwise. */
	var patternNames:Null<Array<{name:String, type:CompilerType, span:SourceSpan}>>;

	function isAssignableTo(actual:CompilerType, expected:CompilerType):Bool;

	/** With `CompileOptions.checkResolution`, whether the body resolver names `name`'s declaration for this reference. */
	var checkResolution:Bool;

	function checkResolved(referenceName:String, span:SourceSpan, name:String, scope:Scope):Void;
	function enumCaseCovered(type:CompilerType, constructorIndex:Int, cases:Array<TypedSwitchCoverageCase>):Bool;

	/** The values of a closed enum abstract keyed as switch cases are (with `null` for a nullable one), or null when the subject is not one. */
	function closedEnumAbstractValues(type:CompilerType):Null<Array<{name:String, key:String}>>;
}
