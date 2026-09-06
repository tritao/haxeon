package compiler.syntax;

import compiler.Source.SourceSpan;

/** Source-level type syntax before name resolution and semantic checking. */
enum AstType {
	IntType;
	BoolType;
	FloatType;
	StringType;
	VoidType;
	InferredType;
	NativeAbstractType(name:String);
	NamedType(name:String);
	AppliedType(name:String, arguments:Array<AstType>);
	ArrayType(element:AstType);
	MapType(key:AstType, value:AstType);
	NullableType(element:AstType);
	FunctionType(arguments:Array<AstType>, result:AstType);
	AnonymousType(fields:Array<AstAnonymousField>);
}

/** One field declared by an anonymous structural type. */
typedef AstAnonymousField = {final name:String; final type:AstType; final optional:Bool; final span:SourceSpan;}

/** Function parameter syntax, including its optional default expression. */
typedef AstArgument = {
	final name:String;
	final type:AstType;
	final span:SourceSpan;
	final ?optional:Bool;
	final ?defaultValue:AstExpression;
}

/** Source spelling of a field's read or write accessor policy. */
enum AstFieldAccess {
	DefaultAccess;
	NullAccess;
	NeverAccess;
	GetAccess;
	SetAccess;
	DynamicAccess;
}

/** Parsed class field before annotation inference and accessor validation. */
typedef AstField = {
	final name:String;
	final type:Null<AstType>;
	final initializer:Null<AstExpression>;
	final readAccess:Null<AstFieldAccess>;
	final writeAccess:Null<AstFieldAccess>;
	final isStatic:Bool;
	final isFinal:Bool;
	final span:SourceSpan;
}

/** Parsed class declaration and its unresolved inheritance relationships. */
typedef AstClass = {
	final name:String;
	final typeParameters:Array<String>;
	final isPrivate:Bool;
	final metadata:Array<AstMetadata>;
	final base:Null<AstType>;
	final interfaces:Array<AstType>;
	final fields:Array<AstField>;
	final methods:Array<AstFunction>;
	final span:SourceSpan;
}

/** Metadata annotation attached to a source declaration. */
typedef AstMetadata = {final name:String; final arguments:Array<AstExpression>; final span:SourceSpan;}

/** Parsed interface declaration before inherited methods are resolved. */
typedef AstInterface = {
	final name:String;
	final typeParameters:Array<String>;
	final bases:Array<AstType>;
	final methods:Array<AstFunction>;
	final span:SourceSpan;
}

/** Source typedef that the declaration index expands during type resolution. */
typedef AstTypeAlias = {
	final name:String;
	final typeParameters:Array<String>;
	final type:AstType;
	final isPrivate:Bool;
	final span:SourceSpan;
}

/** One parameter in an enum constructor declaration. */
typedef AstEnumParameter = {final name:Null<String>; final type:AstType; final optional:Bool; final span:SourceSpan;}

/** Parsed enum constructor and its ordered payload parameters. */
typedef AstEnumCase = {final name:String; final params:Array<AstEnumParameter>; final span:SourceSpan;}

/** Parsed algebraic enum declaration. */
typedef AstEnum = {final name:String; final typeParameters:Array<String>; final cases:Array<AstEnumCase>; final span:SourceSpan;}

/** One named constant declared by an enum abstract. */
typedef AstEnumAbstractValue = {final name:String; final value:AstExpression; final span:SourceSpan;}

/** Parsed enum abstract, including explicit conversion relationships. */
typedef AstEnumAbstract = {
	final name:String;
	final underlying:AstType;
	final fromTypes:Array<AstType>;
	final toTypes:Array<AstType>;
	final values:Array<AstEnumAbstractValue>;
	final span:SourceSpan;
}

/** Parsed non-enum abstract and the methods exposed through its underlying type. */
typedef AstAbstract = {
	final name:String;
	final typeParameters:Array<String>;
	final underlying:AstType;
	final fromTypes:Array<AstType>;
	final toTypes:Array<AstType>;
	final methods:Array<AstFunction>;
	final span:SourceSpan;
}

/** One typed catch arm in a parsed try statement. */
typedef AstCatch = {final name:String; final type:AstType; final statements:Array<AstStatement>; final span:SourceSpan;}

/** Parsed expression tree; each constructor retains its complete source span. */
enum AstExpression {
	IntegerLiteral(value:Int, span:SourceSpan);
	FloatLiteral(value:Float, span:SourceSpan);
	StringLiteral(value:String, span:SourceSpan);
	BoolLiteral(value:Bool, span:SourceSpan);
	NullLiteral(span:SourceSpan);
	Unreachable(span:SourceSpan);
	Variable(name:String, span:SourceSpan);
	Member(object:AstExpression, name:String, span:SourceSpan);
	Add(left:AstExpression, right:AstExpression, span:SourceSpan);
	Sub(left:AstExpression, right:AstExpression, span:SourceSpan);
	Mul(left:AstExpression, right:AstExpression, span:SourceSpan);
	Div(left:AstExpression, right:AstExpression, span:SourceSpan);
	Mod(left:AstExpression, right:AstExpression, span:SourceSpan);
	BitAnd(left:AstExpression, right:AstExpression, span:SourceSpan);
	BitXor(left:AstExpression, right:AstExpression, span:SourceSpan);
	BitOr(left:AstExpression, right:AstExpression, span:SourceSpan);
	ShiftLeft(left:AstExpression, right:AstExpression, span:SourceSpan);
	ShiftRight(left:AstExpression, right:AstExpression, span:SourceSpan);
	UnsignedShiftRight(left:AstExpression, right:AstExpression, span:SourceSpan);
	Negate(value:AstExpression, span:SourceSpan);
	Less(left:AstExpression, right:AstExpression, span:SourceSpan);
	LessEqual(left:AstExpression, right:AstExpression, span:SourceSpan);
	Greater(left:AstExpression, right:AstExpression, span:SourceSpan);
	GreaterEqual(left:AstExpression, right:AstExpression, span:SourceSpan);
	Equal(left:AstExpression, right:AstExpression, span:SourceSpan);
	NotEqual(left:AstExpression, right:AstExpression, span:SourceSpan);
	Not(value:AstExpression, span:SourceSpan);
	And(left:AstExpression, right:AstExpression, span:SourceSpan);
	Or(left:AstExpression, right:AstExpression, span:SourceSpan);
	Conditional(condition:AstExpression, whenTrue:AstExpression, whenFalse:AstExpression, span:SourceSpan);
	BlockExpression(statements:Array<AstStatement>, result:AstExpression, span:SourceSpan);
	ThrowExpression(expression:AstExpression, span:SourceSpan);
	Cast(expression:AstExpression, target:Null<AstType>, span:SourceSpan);
	SwitchExpression(expression:AstExpression, cases:Array<AstSwitchExpressionCase>, defaultExpression:Null<AstExpression>, span:SourceSpan);
	ObjectLiteral(fields:Array<AstObjectField>, span:SourceSpan);
	ArrayLiteral(values:Array<AstExpression>, span:SourceSpan);
	MapLiteral(entries:Array<AstMapEntry>, span:SourceSpan);
	ArrayComprehension(keyName:String, valueName:Null<String>, iterable:AstExpression, condition:Null<AstExpression>, value:AstExpression, span:SourceSpan);
	MapComprehension(keyName:String, valueName:Null<String>, iterable:AstExpression, condition:Null<AstExpression>, key:AstExpression, value:AstExpression,
		span:SourceSpan);
	Range(start:AstExpression, end:AstExpression, span:SourceSpan);
	Call(name:String, arguments:Array<AstExpression>, span:SourceSpan);
	MethodCall(object:AstExpression, name:String, arguments:Array<AstExpression>, span:SourceSpan);
	New(typeName:String, arguments:Array<AstExpression>, span:SourceSpan);
	NewGeneric(typeName:String, typeArguments:Array<AstType>, arguments:Array<AstExpression>, span:SourceSpan);
	NewArray(element:AstType, length:AstExpression, span:SourceSpan);
	NewMap(key:AstType, value:AstType, span:SourceSpan);
	Index(array:AstExpression, index:AstExpression, span:SourceSpan);
	PostfixIncrement(target:AstExpression, delta:Int, span:SourceSpan);
	Lambda(arguments:Array<AstArgument>, statements:Array<AstStatement>, span:SourceSpan);
}

/** Named value supplied by an object-literal expression. */
typedef AstObjectField = {final name:String; final value:AstExpression; final span:SourceSpan;}

/** Key/value pair supplied by a map-literal expression. */
typedef AstMapEntry = {final key:AstExpression; final value:AstExpression; final span:SourceSpan;}

/** One guarded arm of a switch used as an expression. */
typedef AstSwitchExpressionCase = {
	final value:AstExpression;
	final guard:Null<AstExpression>;
	final result:AstExpression;
	final span:SourceSpan;
}

/** Parsed statement tree before binding resolution and type checking. */
enum AstStatement {
	UninitializedDeclaration(name:String, type:AstType, span:SourceSpan);
	VarDeclaration(name:String, ?type:AstType, initializer:AstExpression, span:SourceSpan);
	Assignment(name:String, expression:AstExpression, span:SourceSpan);
	IndexAssignment(array:AstExpression, index:AstExpression, expression:AstExpression, span:SourceSpan);
	FieldAssignment(object:AstExpression, field:String, expression:AstExpression, span:SourceSpan);
	Return(expression:AstExpression, span:SourceSpan);
	ReturnVoid(span:SourceSpan);
	Throw(expression:AstExpression, span:SourceSpan);
	Try(tryBranch:Array<AstStatement>, catches:Array<AstCatch>, span:SourceSpan);
	If(condition:AstExpression, thenBranch:Array<AstStatement>, elseBranch:Array<AstStatement>, span:SourceSpan);
	While(condition:AstExpression, body:Array<AstStatement>, span:SourceSpan);
	DoWhile(body:Array<AstStatement>, condition:AstExpression, span:SourceSpan);
	ForIn(keyName:String, valueName:Null<String>, iterable:AstExpression, body:Array<AstStatement>, span:SourceSpan);
	Break(span:SourceSpan);
	Continue(span:SourceSpan);
	Switch(expression:AstExpression, cases:Array<AstSwitchCase>, defaultBranch:Array<AstStatement>, hasDefault:Bool, span:SourceSpan);
	Increment(name:String, delta:Int, span:SourceSpan);
	Expression(expression:AstExpression, span:SourceSpan);
}

/** One guarded statement arm of a parsed switch. */
typedef AstSwitchCase = {
	final value:AstExpression;
	final guard:Null<AstExpression>;
	final statements:Array<AstStatement>;
	final span:SourceSpan;
}

/** Parsed function or method declaration with an unresolved signature and body. */
typedef AstFunction = {
	final name:String;
	final isStatic:Bool;
	final ?typeParameters:Array<String>;
	final ?typeConstraints:Array<AstTypeConstraint>;
	final arguments:Array<AstArgument>;
	final result:AstType;
	final statements:Array<AstStatement>;
	final span:SourceSpan;
}

/** Upper bound attached to a generic function or method parameter. */
typedef AstTypeConstraint = {final parameter:String; final type:AstType; final span:SourceSpan;}

/** Complete parsed module, grouped by declaration kind for semantic indexing. */
typedef AstProgram = {
	final packageName:Null<String>;
	final imports:Array<String>;
	final importAliases:Map<String, String>;
	final aliases:Array<AstTypeAlias>;
	final enums:Array<AstEnum>;
	final enumAbstracts:Array<AstEnumAbstract>;
	final abstracts:Array<AstAbstract>;
	final interfaces:Array<AstInterface>;
	final classes:Array<AstClass>;
	final functions:Array<AstFunction>;
}
