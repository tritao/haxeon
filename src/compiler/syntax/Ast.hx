package compiler.syntax;

import compiler.core.Source.SourceSpan;

/**
 * A local the typer introduces while it types a body, in syntax it builds (docs/design/BODY_RESOLUTION.md): never named in
 * the source, so no source name can refer to it: the typer finds its binding by the object (`Scope.bindingOfTemporary`).
 * `name` is how diagnostics and generated code name it.
 */
class TemporaryLocal {
	public final name:String;

	public function new(name:String)
		this.name = name;
}

/** Source-level type syntax before name resolution and semantic checking. */
enum AstType {
	IntType;
	BoolType;
	FloatType;
	StringType;
	VoidType;
	InferredType;

	/** Recovery-only placeholder for an incomplete or malformed type. */
	ErrorType(span:SourceSpan);

	NativeAbstractType(declaration:String, tag:String);
	NamedType(name:String);
	AppliedType(name:String, arguments:Array<AstType>);
	ArrayType(element:AstType);
	MapType(key:AstType, value:AstType);
	NullableType(element:AstType);
	/** `optional` flags the arguments written `?x:T`, whose type is then `Null<T>`; see `CompilerType.TFunction`. */
	FunctionType(arguments:Array<AstType>, result:AstType, optional:Array<Bool>);
	AnonymousType(fields:Array<AstAnonymousField>);
}

/** One field declared by an anonymous structural type. */
typedef AstAnonymousField = {
	final name:String;
	final type:AstType;
	final optional:Bool;
	final isFinal:Bool;
	final metadata:Array<AstMetadata>;
	final span:SourceSpan;
}

/** Function parameter syntax, including its optional default expression. */
typedef AstArgument = {
	final name:String;
	final type:AstType;
	final span:SourceSpan;

	/** Written `?x`. A default value makes the argument optional too: see `AstPredicates.isOptionalArgument`. */
	final ?optional:Bool;
	final ?defaultValue:AstExpression;

	/** Full source range of a declaration default, including grouping parentheses. */
	final ?defaultValueSpan:SourceSpan;

	/** The temporary this argument is, when the typer built the function (`TemporaryLocal`). */
	final ?local:TemporaryLocal;
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

/**
 * A declaration's access level as its source writes it. `Unwritten` leaves it to Haxe's rules for its kind: a module's types
 * and its variables and functions are public, a class's or an abstract's members private (public with `@:publicFields` or
 * `extern`), an interface's members public, and an override has the visibility of what it overrides. An interface's member
 * is public whatever it is written; one written `private` is left out of the API.
 */
enum abstract AstVisibility(Int) {
	var Unwritten;
	var Public;
	var Private;

	/** `internal`: public to the code of the package that declares it, and to no other package's. */
	var Internal;

	/** Whether code outside the declaration's own scope may reach it (public or internal), `byDefault` when unwritten. */
	public inline function reachable(byDefault:Bool):Bool
		return abstract == Unwritten ? byDefault : abstract != Private;

	/** Whether it is written `internal`. */
	public inline function isInternal():Bool
		return abstract == Internal;

	/** Its modifier as source writes it, "" when unwritten: what a declaration's printed signature shows. */
	public function modifier():String
		return switch abstract {
			case Public: "public";
			case Private: "private";
			case Internal: "internal";
			case _: "";
		};
}

/** Parsed class field before annotation inference and accessor validation. */
typedef AstField = {
	final name:String;
	/** Its access level as written. */
	final visibility:AstVisibility;
	final metadata:Array<AstMetadata>;
	/**
	 * The field's annotation, or null when the source gives it none: its type is then its initializer's, which the typer gives
	 * (`DeclarationTypes`), and a reader of it reads the initializer's unit (`FactAspect.Unit`).
	 */
	final type:Null<AstType>;

	final initializer:Null<AstExpression>;
	final readAccess:Null<AstFieldAccess>;
	final writeAccess:Null<AstFieldAccess>;
	final isStatic:Bool;
	final isInline:Bool;
	final isFinal:Bool;

	/** From `var` (or the name), to the end: where a reference to the field points. */
	final span:SourceSpan;

	/**
	 * From the field's first modifier, after its metadata, to the end: Haxe's position of the field, where it reports a field's
	 * declaration errors ("Method get_x required by property x is missing"). Null where it is `span`.
	 */
	final ?declarationSpan:SourceSpan;
}

/** Parsed class declaration and its unresolved inheritance relationships. */
typedef AstClass = {
	final name:String;
	/** Its access level as written. */
	final visibility:AstVisibility;

	/** Set when this declaration used the `struct` keyword. */
	final ?isStruct:Bool;

	final ?isExtern:Bool;
	final typeParameters:Array<String>;
	final ?typeConstraints:Array<AstTypeConstraint>;
	final metadata:Array<AstMetadata>;
	final base:Null<AstType>;
	final interfaces:Array<AstType>;
	final fields:Array<AstField>;
	final methods:Array<AstFunction>;
	final span:SourceSpan;
}

/** Metadata annotation attached to a source declaration. */
typedef AstMetadata = {
	final name:String;
	final arguments:Array<AstExpression>;
	final span:SourceSpan;
}

/** Parsed interface declaration before inherited methods are resolved. */
typedef AstInterface = {
	final ?documentationMetadata:Array<AstMetadata>;
	final name:String;
	/** Its access level as written. */
	final visibility:AstVisibility;

	final typeParameters:Array<String>;
	final ?typeConstraints:Array<AstTypeConstraint>;
	final bases:Array<AstType>;

	/**
	 * Its variables and properties, `var x:Int`, `var area(get, never):Int`: an implementing class has each with a matching access
	 * (`InterfaceProperties`). An access through the interface calls a method of the interface, the accessor or, for a `default`
	 * side, the hidden accessor every implementing class is given (`InterfaceFieldAccessors`).
	 */
	final fields:Array<AstField>;

	final methods:Array<AstFunction>;
	final span:SourceSpan;
}

/** Source typedef that the declaration index expands during type resolution. */
typedef AstTypeAlias = {
	final name:String;
	/** Its access level as written. */
	final visibility:AstVisibility;

	final metadata:Array<AstMetadata>;
	final typeParameters:Array<String>;
	final ?typeConstraints:Array<AstTypeConstraint>;
	final type:AstType;
	final span:SourceSpan;
}

/** One parameter in an enum constructor declaration. */
typedef AstEnumParameter = {
	final name:Null<String>;
	final type:AstType;
	final optional:Bool;
	final span:SourceSpan;
}

/** Parsed enum constructor and its ordered payload parameters. */
typedef AstEnumCase = {
	final name:String;
	final metadata:Array<AstMetadata>;
	final params:Array<AstEnumParameter>;

	/** The values it gives its enum's per-case constants (`Float {componentCount: 1}`), in the order written. */
	final ?constants:Array<AstEnumCaseConstant>;

	final span:SourceSpan;
}

/** A per-case constant an enum declares (`final componentCount:Int;`), which each case sets (docs/design/ENUM_MEMBERS.md). */
typedef AstEnumConstant = {
	final name:String;
	final visibility:AstVisibility;
	final metadata:Array<AstMetadata>;
	final type:AstType;

	/** The value of a case that does not set it; null when every case must. */
	final defaultValue:Null<AstExpression>;

	final span:SourceSpan;
}

/** One case's value for a per-case constant: `componentCount = 1`. */
typedef AstEnumCaseConstant = {
	final name:String;
	final value:AstExpression;
	final span:SourceSpan;
}

/** Parsed algebraic enum declaration. */
typedef AstEnum = {
	final name:String;
	/** Its access level as written. */
	final visibility:AstVisibility;

	final typeParameters:Array<String>;
	final ?typeConstraints:Array<AstTypeConstraint>;
	final ?conformances:Array<AstType>;
	final ?methods:Array<AstFunction>;

	/** Its static variables; the module keeps them in a hidden class (`TypeStatics`). */
	final ?fields:Array<AstField>;

	/** Its per-case constants; each becomes a getter among its methods (`EnumConstants`). */
	final ?constants:Array<AstEnumConstant>;

	final metadata:Array<AstMetadata>;
	final cases:Array<AstEnumCase>;
	final span:SourceSpan;
}

/** One named constant declared by an enum abstract. */
typedef AstEnumAbstractValue = {
	final visibility:AstVisibility;
	final name:String;
	final metadata:Array<AstMetadata>;
	final value:AstExpression;
	final span:SourceSpan;
}

/**
 * Parsed abstract. An enum abstract (`enum abstract`) is an abstract that also declares values; like any abstract it may have
 * methods, properties and statics.
 */
typedef AstAbstract = {
	final name:String;
	/** Its access level as written. */
	final visibility:AstVisibility;

	final ?isExtern:Bool;
	final ?metadata:Array<AstMetadata>;
	final typeParameters:Array<String>;
	final ?typeConstraints:Array<AstTypeConstraint>;

	/** The interfaces an enum abstract declares with `implements`. */
	final ?conformances:Array<AstType>;

	final underlying:AstType;
	final fromTypes:Array<AstType>;
	final toTypes:Array<AstType>;

	/** The abstract's properties, `var name(get, never):Type`: an abstract stores nothing but its underlying value. */
	final fields:Array<AstField>;

	final methods:Array<AstFunction>;

	/**
	 * An enum abstract's values in declaration order; null for a plain abstract. Null rather than empty, because an enum
	 * abstract may declare no values and is still one (its switches are closed over none).
	 */
	final ?values:Array<AstEnumAbstractValue>;

	final span:SourceSpan;
}

/** One typed catch arm in a parsed try statement. */
typedef AstCatch = {
	final name:String;
	final type:AstType;
	final statements:Array<AstStatement>;
	final span:SourceSpan;
}

/** Metadata on a statement or expression that changes how the typer checks what it wraps. */
enum ScopeMetadata {
	/** `@:privateAccess`: private members are reachable. */
	PrivateAccess;

	/** `@:nullSafety(Off)`: the null-safety checker does not check it. */
	NullSafetyOff;
}

/** Parsed expression tree; each constructor retains its complete source span. */
enum AstExpression {
	/** An expression with metadata that changes how it is checked (`@:privateAccess`, `@:nullSafety(Off)`). */
	AnnotatedExpression(metadata:ScopeMetadata, expression:AstExpression, span:SourceSpan);

	IntegerLiteral(value:Int, span:SourceSpan);
	FloatLiteral(value:Float, span:SourceSpan);
	StringLiteral(value:String, span:SourceSpan);
	BoolLiteral(value:Bool, span:SourceSpan);
	NullLiteral(span:SourceSpan);
	Unreachable(span:SourceSpan);
	EmptyExpression(span:SourceSpan);

	/** Recovery-only placeholder for an incomplete or malformed expression. */
	ErrorExpression(span:SourceSpan);

	Variable(name:String, span:SourceSpan);

	/** A read of a temporary the typer introduced. */
	TemporaryVariable(local:TemporaryLocal, span:SourceSpan);

	/**
	 * A read of the source local `name` declared at offset `declaration` (its declaration's key, `BindingWalker.key`), in syntax
	 * the typer built: generated code reaches a source local by its declaration, not by its name.
	 */
	DeclaredVariable(name:String, declaration:Int, span:SourceSpan);

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

	/** The switch pattern `name = pattern`: matches what `pattern` matches and binds the matched value to `name`. Only valid in a case. */
	Capture(name:String, pattern:AstExpression, span:SourceSpan);

	/**
	 * The switch pattern `expression => pattern`: `expression`, where `_` is the value being matched, must match `pattern`
	 * (`case _.length => 3:`, `case parse(_) => value:`). Only valid in a case.
	 */
	Extractor(expression:AstExpression, pattern:AstExpression, span:SourceSpan);

	/** `...values` as a call's last argument: the array whose elements a rest parameter receives. Only valid there. */
	Spread(expression:AstExpression, span:SourceSpan);

	ThrowExpression(expression:AstExpression, span:SourceSpan);

	/** `break` or `continue` where a value is expected, as in `if (skip) continue else value`: it gives no value. */
	BreakExpression(span:SourceSpan);
	ContinueExpression(span:SourceSpan);
	Cast(expression:AstExpression, target:Null<AstType>, span:SourceSpan);

	/** `(expression : type)`: the value as a `type`, as an assignment to one converts it (an abstract's `@:to`, `@:from`). */
	CheckType(expression:AstExpression, type:AstType, span:SourceSpan);
	SwitchExpression(expression:AstExpression, cases:Array<AstSwitchExpressionCase>,
		defaultExpression:Null<AstExpression>, span:SourceSpan);
	ObjectLiteral(fields:Array<AstObjectField>, span:SourceSpan);
	ArrayLiteral(values:Array<AstExpression>, span:SourceSpan);
	MapLiteral(entries:Array<AstMapEntry>, span:SourceSpan);
	ArrayComprehension(keyName:String, valueName:Null<String>, iterable:AstExpression, condition:Null<AstExpression>,
		value:AstExpression, flattened:Bool,
		span:SourceSpan);
	MapComprehension(keyName:String, valueName:Null<String>, iterable:AstExpression, condition:Null<AstExpression>,
		key:AstExpression, value:AstExpression,
		span:SourceSpan);
	Range(start:AstExpression, end:AstExpression, span:SourceSpan);
	Call(name:String, arguments:Array<AstExpression>, span:SourceSpan);
	NativeLayoutQuery(kind:NativeLayoutQueryKind, type:AstType, field:Null<String>, span:SourceSpan);
	/** An uninstantiated root may still contain the field suffix until name resolution. */
	KeyPathLiteral(root:AstType, fields:Array<String>, span:SourceSpan);
	ClosureCall(callee:AstExpression, arguments:Array<AstExpression>, span:SourceSpan);
	MethodCall(object:AstExpression, name:String, arguments:Array<AstExpression>, span:SourceSpan);
	New(typeName:String, arguments:Array<AstExpression>, span:SourceSpan);
	NewGeneric(typeName:String, typeArguments:Array<AstType>, arguments:Array<AstExpression>, span:SourceSpan);
	NewArray(element:AstType, length:AstExpression, span:SourceSpan);
	NewMap(key:AstType, value:AstType, span:SourceSpan);
	Index(array:AstExpression, index:AstExpression, span:SourceSpan);
	PostfixIncrement(target:AstExpression, delta:Int, span:SourceSpan);

	/**
	 * An assignment used as a value (`(a = b)`, `(a += b)`, `++a`): `assignment`, an `Assignment`, `FieldAssignment` or
	 * `IndexAssignment`, stores, and the value is Haxe's: the result of the setter where a property's setter stores it, else the
	 * value stored. A compound target's receiver and index are bound before it (`AssignmentTarget`).
	 */
	AssignmentValue(assignment:AstStatement, span:SourceSpan);

	/**
	 * `identity` is the parser's `<member>#<ordinal>` name for the lambda; see `LambdaName`. `isInline` marks a local
	 * `inline function`, which each call replaces by its body (`LocalInlineFunctions`). `isNamed` marks the lambda of a
	 * named local function (`function f() ...`), whose name is bound in its own body, as Haxe binds it; a lambda a `var`
	 * holds is not in scope in its own initializer.
	 */
	Lambda(arguments:Array<AstArgument>, statements:Array<AstStatement>, identity:String, span:SourceSpan,
		?isInline:Bool, ?isNamed:Bool, ?generic:AstLocalGenerics);
}

/** Compile-time query over a fixed native ABI layout. */
enum NativeLayoutQueryKind {
	SizeOf;
	AlignOf;
	OffsetOf;
	TypeInfo;
}

/** Named value supplied by an object-literal expression. */
typedef AstObjectField = {
	final name:String;
	final value:AstExpression;
	final span:SourceSpan;
}

/** Key/value pair supplied by a map-literal expression. */
typedef AstMapEntry = {
	final key:AstExpression;
	final value:AstExpression;
	final span:SourceSpan;
}

/** One guarded arm of a switch used as an expression: `case A, B if guard: result` has the patterns `A` and `B`. */
typedef AstSwitchExpressionCase = {
	final patterns:Array<AstExpression>;
	final guard:Null<AstExpression>;
	final result:AstExpression;
	final span:SourceSpan;
}

/** Parsed statement tree before binding resolution and type checking. */
enum AstStatement {
	/** A statement with metadata that changes how it is checked (`@:privateAccess`, `@:nullSafety(Off)`). */
	AnnotatedStatement(metadata:ScopeMetadata, statement:AstStatement, span:SourceSpan);

	/** Recovery-only placeholder retaining the malformed statement location. */
	ErrorStatement(span:SourceSpan);

	UninitializedDeclaration(name:String, type:AstType, span:SourceSpan);
	VarDeclaration(name:String, ?type:AstType, initializer:AstExpression, span:SourceSpan);
	ScopedDeclaration(name:String, ?type:AstType, initializer:AstExpression, span:SourceSpan);
	Assignment(name:String, expression:AstExpression, span:SourceSpan);

	/** The declaration of a temporary the typer introduced. */
	TemporaryDeclaration(local:TemporaryLocal, ?type:AstType, initializer:AstExpression, span:SourceSpan);

	/** An assignment of a temporary the typer introduced. */
	TemporaryAssignment(local:TemporaryLocal, expression:AstExpression, span:SourceSpan);

	/** An assignment of the source local `name` declared at offset `declaration`, in syntax the typer built (`DeclaredVariable`). */
	DeclaredAssignment(name:String, declaration:Int, expression:AstExpression, span:SourceSpan);

	IndexAssignment(array:AstExpression, index:AstExpression, expression:AstExpression, span:SourceSpan);
	FieldAssignment(object:AstExpression, field:String, expression:AstExpression, span:SourceSpan);
	Return(expression:AstExpression, span:SourceSpan);
	ReturnVoid(span:SourceSpan);
	Throw(expression:AstExpression, span:SourceSpan);
	/** Register this body for execution when the enclosing lexical block exits. */
	Defer(body:Array<AstStatement>, span:SourceSpan);
	Try(tryBranch:Array<AstStatement>, catches:Array<AstCatch>, span:SourceSpan);
	If(condition:AstExpression, thenBranch:Array<AstStatement>, elseBranch:Array<AstStatement>, span:SourceSpan);
	While(condition:AstExpression, body:Array<AstStatement>, span:SourceSpan);
	DoWhile(body:Array<AstStatement>, condition:AstExpression, span:SourceSpan);
	ForIn(keyName:String, valueName:Null<String>, iterable:AstExpression, body:Array<AstStatement>, span:SourceSpan);
	Break(span:SourceSpan);
	Continue(span:SourceSpan);
	Switch(expression:AstExpression, cases:Array<AstSwitchCase>, defaultBranch:Array<AstStatement>, hasDefault:Bool,
		span:SourceSpan);
	Increment(name:String, delta:Int, span:SourceSpan);
	Expression(expression:AstExpression, span:SourceSpan);
}

/**
 * One guarded statement arm of a parsed switch: `case A, B if guard:` has the patterns `A` and `B` (and the alternatives of
 * `A | B`), which share the guard and the statements (docs/design/SWITCH_CASES.md).
 */
typedef AstSwitchCase = {
	final patterns:Array<AstExpression>;
	final guard:Null<AstExpression>;
	final statements:Array<AstStatement>;
	final span:SourceSpan;
}

/** Parsed function or method declaration with an unresolved signature and body. */
typedef AstFunction = {
	/** Its access level as written. */
	final visibility:AstVisibility;

	/** Explicit override modifier, checked against inherited instance methods. */
	final ?isOverride:Bool;
	final ?isDynamic:Bool;
	final name:String;
	final isStatic:Bool;

	final ?isExtern:Bool;

	/** Declared `inline`; the inliner treats it as a strong hint. */
	final ?isInline:Bool;

	final ?metadata:Array<AstMetadata>;
	final ?typeParameters:Array<String>;
	final ?typeConstraints:Array<AstTypeConstraint>;
	final arguments:Array<AstArgument>;
	final result:AstType;
	final statements:Array<AstStatement>;
	final span:SourceSpan;
}

typedef AstLocalGenerics = {
	final parameters:Array<String>;
	final constraints:Array<AstTypeConstraint>;
}

/** Upper bound attached to a generic function or method parameter. */
typedef AstTypeConstraint = {
	final parameter:String;
	final type:AstType;
	final span:SourceSpan;
}

/** One source import and the optional local name declared by that occurrence. */
typedef AstImport = {
	final path:String;
	final alias:Null<String>;
}

/** One `using pack.Tools;` of a module: the static functions of what it names become extensions in the module (Haxe's order). */
typedef AstUsing = {
	final path:String;
	final span:SourceSpan;
}

/** Complete parsed module, grouped by declaration kind for semantic indexing. */
typedef AstProgram = {
	final packageName:Null<String>;
	final imports:Array<AstImport>;
	final aliases:Array<AstTypeAlias>;
	final enums:Array<AstEnum>;
	final abstracts:Array<AstAbstract>;
	final interfaces:Array<AstInterface>;
	final classes:Array<AstClass>;
	final functions:Array<AstFunction>;

	/**
	 * Module-level `var` and `final` declarations, as the parser reads them: static fields of no class yet. ModuleFields.fold makes
	 * them static fields of the module's class, the class named like the module, so nothing after parsing sees this list.
	 */
	final ?fields:Array<AstField>;

	/**
	 * The module's `using` declarations in source order, as the parser reads them. Each is also among `imports`, as a `using`
	 * imports what it names. SemanticAssembly resolves them into the program's StaticExtensionTable; a canonical program has none.
	 */
	final ?usings:Array<AstUsing>;
}
