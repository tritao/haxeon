package compiler.types;

import compiler.core.Source.SourceSpan;
import compiler.types.Type.CompilerType;

/** Expression paired with its resolved semantic type and original source span. */
class TypedExpression {
	public final expression:TypedExpressionKind;
	public final type:CompilerType;
	public final span:SourceSpan;
	public final stableFlowValue:Bool;

	/** Source symbol retained when resolution erases it, such as a constant or typedef qualifier. */
	public final semanticReference:Null<String>;

	/** Map whose keys are represented by this array, when the value originated from Map.keys(). */
	public final mapKeySource:Null<TypedExpression>;

	/** Declared storage type for a captured value whose flow type may be narrowed. */
	public final storageType:Null<CompilerType>;

	/**
	 * On a boundary the elaboration pass made (`GenericElaboration`), the conversion it stands for in the body's own type
	 * parameters; null on every other node.
	 */
	public final parameterSource:Null<TypedParameterSource>;

	public function new(expression, type, span, stableFlowValue:Bool = false, ?mapKeySource:TypedExpression,
			?storageType:CompilerType,
			?semanticReference:String, ?parameterSource:TypedParameterSource) {
		this.expression = expression;
		this.type = type;
		this.span = span;
		this.stableFlowValue = stableFlowValue;
		this.mapKeySource = mapKeySource;
		this.storageType = storageType;
		this.semanticReference = semanticReference;
		this.parameterSource = parameterSource;
	}
}

/**
 * The semantic side of a boundary between a type parameter and another type: `source` converted to `target`, both as the body's
 * own typing has them (`T` to `Dynamic`, `Dynamic` to `T`, `T` to its bound), and the substitution the boundary was made for.
 * Lowering reads it where the physical conversion alone loses what the value is (docs/design/GENERIC_TYPING_ONCE.md, stage 2).
 */
typedef TypedParameterSource = {
	final source:CompilerType;
	final target:CompilerType;
	final substitutions:Map<String, CompilerType>;
}

/** Which operation a `TParameterOperation` stands for; the elaboration pass chooses its helper for the substituted types. */
enum ParameterOperation {
	/** An equality intrinsic, by name (`Equality.equals`, `Equality.sameForChange`, `Hashing.keyEquals`). */
	Equality(name:String);

	/** `Array.indexOf`, `contains` or `remove`, by name, of a value in an array. */
	ArraySearch(name:String);

	/** `Hashing.hash` of a value. */
	Hash;

	/** A value turned into a String, as concatenation and `Std.string` do (`StringConversion`). */
	ToString;

	/** `RawPtr.load`, `store` or `offset`, by name, whose access depends on the pointee's layout. */
	RawPointer(name:String);

	/** `sizeof`, `alignof`, `offsetof` or `typeInfo` of a type: its layout or descriptor. */
	LayoutQuery(kind:compiler.syntax.Ast.NativeLayoutQueryKind, type:CompilerType, field:Null<String>);
}

/** Which conversion a `TParameterConversion` stands for; the elaboration pass makes it for the substituted types. */
enum ParameterConversionKind {
	/** A value converted to an expected type (`ConversionResolver.coerce`). */
	Coerce;

	/** A value crossing between its physical and semantic type (`TypeRepresentation.boundaryCast`). */
	Boundary;

	/** An unsafe `cast` of a value to a type (`ExpressionTyper.typeCast`). */
	Cast;
}

/** Type-checked expression operations consumed by IR generation. */
enum TypedExpressionKind {
	TIntLiteral(value:Int);
	TFloatLiteral(value:Float);
	TStringLiteral(value:String);
	TRuntimeDataAddress(bytes:Array<Int>);
	TBoolLiteral(value:Bool);
	TEnumLiteral(name:String, index:Int);
	TEnumConstruct(name:String, index:Int, arguments:Array<TypedExpression>);
	TEnumIndex(value:TypedExpression);
	TEnumField(value:TypedExpression, constructor:Int, field:Int);
	TNullLiteral;
	TUnreachable;
	TVoidLiteral;
	TNullableWrap(value:TypedExpression);

	/** A value class instance bound to a new storage location: a distinct copy, so the two never alias. */
	TCopy(value:TypedExpression, layout:ValueCopyLayout);

	TIntToFloat(value:TypedExpression);
	TIntToInt64(value:TypedExpression);
	TFloatToInt(value:TypedExpression);
	TToDynamic(value:TypedExpression);
	/** A local; IR generation reads it through its cell when the function keeps it in one (`TypedFunction.cells`). */
	TLocal(name:String);

	/** A capture of a lambda, through its cell when the lambda's environment holds one (`TypedFunction.cellCaptures`). */
	TCaptured(name:String);
	TClassRef(name:String);
	TStaticField(name:String, field:String);
	TFunctionRef(name:String);
	TMethodRef(object:TypedExpression, functionName:String, ?dynamicImplementation:Bool);
	TLambda(name:String, environment:Null<String>, captures:Array<TypedCapture>);
	TAdd(left:TypedExpression, right:TypedExpression);
	TSub(left:TypedExpression, right:TypedExpression);
	TMul(left:TypedExpression, right:TypedExpression);
	TDiv(left:TypedExpression, right:TypedExpression);
	TMod(left:TypedExpression, right:TypedExpression);
	TBitAnd(left:TypedExpression, right:TypedExpression);
	TBitXor(left:TypedExpression, right:TypedExpression);
	TBitOr(left:TypedExpression, right:TypedExpression);
	TShiftLeft(left:TypedExpression, right:TypedExpression);
	TShiftRight(left:TypedExpression, right:TypedExpression);
	TUnsignedShiftRight(left:TypedExpression, right:TypedExpression);
	TNegate(value:TypedExpression);
	TLess(left:TypedExpression, right:TypedExpression);
	TLessEqual(left:TypedExpression, right:TypedExpression);
	TEqual(left:TypedExpression, right:TypedExpression);
	TNot(value:TypedExpression);
	TAnd(left:TypedExpression, right:TypedExpression);
	TOr(left:TypedExpression, right:TypedExpression);
	TConditional(condition:TypedExpression, whenTrue:TypedExpression, whenFalse:TypedExpression);
	TBlockExpression(statements:Array<TypedStatement>, result:TypedExpression);
	TThrowExpression(expression:TypedExpression);

	/** `break` or `continue` where a value is expected: it leaves the innermost loop or goes on to its next round. */
	TBreakExpression;
	TContinueExpression;
	TNoReturn(expression:TypedExpression);
	TCast(expression:TypedExpression);
	TAbiCast(expression:TypedExpression);

	/**
	 * A conversion of `value` to this node's type where either mentions a type parameter of the body: what it is physically
	 * depends on the representation, so the typer records it and the elaboration pass makes it (`GenericElaboration`). No
	 * node of this kind is left after typing.
	 */
	TParameterConversion(value:TypedExpression, kind:ParameterConversionKind);

	/**
	 * An operation on values whose type mentions a type parameter of the body, whose helper depends on the representation:
	 * the elaboration pass chooses it (`GenericElaboration`). No node of this kind is left after typing.
	 */
	TParameterOperation(operation:ParameterOperation, arguments:Array<TypedExpression>);
	TSwitchExpression(expression:TypedExpression, cases:Array<TypedSwitchExpressionCase>,
		defaultExpression:Null<TypedExpression>);
	TObjectLiteral(name:String, fields:Array<TypedObjectField>, isDynamic:Bool);
	TArrayLiteral(values:Array<TypedExpression>);

	/**
	 * The subject of `switch [a, b]`, which Haxe matches element by element without building the array: each element keeps
	 * its own type, and the cases are tuple patterns over them. It is no value, so its type is Void and only a switch
	 * lowers it.
	 */
	TTuple(values:Array<TypedExpression>);

	TMapLiteral(entries:Array<TypedMapEntry>);
	TArrayComprehension(keyName:String, valueName:Null<String>, iterable:TypedExpression,
		condition:Null<TypedExpression>, value:TypedExpression,
		flattened:Bool);
	TMapComprehension(keyName:String, valueName:Null<String>, iterable:TypedExpression, condition:Null<TypedExpression>,
		key:TypedExpression,
		value:TypedExpression);
	TRange(start:TypedExpression, end:TypedExpression);
	TCall(name:String, arguments:Array<TypedExpression>);

	/** A call to a helper the IR does not have yet: a pass makes it from the request, which names the helper's subject and operation. */
	TCNativeCall(name:String, arguments:Array<TypedExpression>);

	TCollectionCall(receiver:TypedExpression, operation:String, arguments:Array<TypedExpression>);
	TClosureCall(callee:TypedExpression, arguments:Array<TypedExpression>);
	TToInterface(value:TypedExpression, name:String);
	TNew(typeName:String, arguments:Array<TypedExpression>, hasConstructor:Bool);
	TNewArray(element:CompilerType, length:TypedExpression);
	TNewMap(key:CompilerType, value:CompilerType);
	TField(object:TypedExpression, name:String);
	TMethodCall(object:TypedExpression, functionName:String, arguments:Array<TypedExpression>);
	TSuperCall(owner:String, arguments:Array<TypedExpression>);
	TIndex(array:TypedExpression, index:TypedExpression);
	TPostfixLocal(name:String, delta:Int);
	TPostfixCaptured(name:String, delta:Int);
	TPostfixStaticField(owner:String, name:String, delta:Int);
	TPostfixField(object:TypedExpression, name:String, delta:Int);
	TPostfixIndex(array:TypedExpression, index:TypedExpression, delta:Int);
	TMapGet(map:TypedExpression, key:TypedExpression);
	TArrayLength(array:TypedExpression);
	TStringLength(value:TypedExpression);
	TStringIndexOf(value:TypedExpression, needle:TypedExpression);
	TStringCharAt(value:TypedExpression, index:TypedExpression);
	TStringCharCodeAt(value:TypedExpression, index:TypedExpression);
	TStringFromCharCode(code:TypedExpression);
	TStringSubstring(value:TypedExpression, start:TypedExpression, end:Null<TypedExpression>);
	TArrayPush(array:TypedExpression, value:TypedExpression);
	TArrayUnshift(array:TypedExpression, value:TypedExpression);
	TArrayPop(array:TypedExpression);
	TArraySort(array:TypedExpression, comparator:TypedExpression);
	TEnumDynamicBox(value:TypedExpression, enumType:CompilerType);
	TEnumDynamicView(array:TypedExpression, enumType:CompilerType);
}

/** Resolved field initializer in a typed object literal. */
typedef TypedObjectField = {
	final name:String;
	final value:TypedExpression;
}

/** Resolved key/value pair in a typed map literal. */
typedef TypedMapEntry = {
	final key:TypedExpression;
	final value:TypedExpression;
}

/** Type-checked arm of a switch expression: its pattern and the value it produces. */
/** One case of a switch expression: an arm per pattern, sharing the guard, and the result typed once. */
typedef TypedSwitchExpressionCase = {
	final arms:Array<TypedSwitchArm>;
	final result:TypedExpression;
}

/** Type-checked statements with explicit storage and dispatch decisions. */
enum TypedStatement {
	TDeclare(name:String, type:CompilerType, span:SourceSpan);
	TVar(name:String, initializer:TypedExpression, span:SourceSpan);
	TAssign(name:String, value:TypedExpression, span:SourceSpan);
	TCapturedAssign(name:String, value:TypedExpression, span:SourceSpan);
	TFieldAssign(object:TypedExpression, name:String, value:TypedExpression, span:SourceSpan);
	TStaticFieldAssign(name:String, field:String, value:TypedExpression, span:SourceSpan);
	TIndexAssign(array:TypedExpression, index:TypedExpression, value:TypedExpression, span:SourceSpan);
	TMapAssign(map:TypedExpression, key:TypedExpression, value:TypedExpression, span:SourceSpan);
	TReturn(expression:TypedExpression, span:SourceSpan);
	TReturnVoid(span:SourceSpan);
	TThrow(expression:TypedExpression, span:SourceSpan);

	/** Cleanup registered at this point and executed on exit from the containing block. */
	TDefer(body:Array<TypedStatement>, span:SourceSpan, scopedDisposal:Bool);

	TTry(tryBranch:Array<TypedStatement>, catches:Array<TypedCatch>, span:SourceSpan);
	TIf(condition:TypedExpression, thenBranch:Array<TypedStatement>, elseBranch:Array<TypedStatement>, span:SourceSpan);
	TWhile(condition:TypedExpression, body:Array<TypedStatement>, span:SourceSpan);
	TDoWhile(body:Array<TypedStatement>, condition:TypedExpression, span:SourceSpan);
	TForIn(keyName:String, valueName:Null<String>, iterable:TypedExpression, body:Array<TypedStatement>,
		span:SourceSpan);
	TBreak(span:SourceSpan);
	TContinue(span:SourceSpan);
	TSwitch(expression:TypedExpression, cases:Array<TypedSwitchCase>, defaultBranch:Array<TypedStatement>,
		hasDefault:Bool, span:SourceSpan);
	TIncrement(name:String, valueType:CompilerType, delta:Int, span:SourceSpan);
	TCapturedIncrement(name:String, valueType:CompilerType, delta:Int, span:SourceSpan);
	TExpression(expression:TypedExpression, span:SourceSpan);
}

/** Type-checked arm of a switch statement: its pattern and the statements it runs. */
/**
 * One case of a switch statement: an arm per pattern (`case A, B:`), sharing the guard, and the statements typed once. Every
 * pattern binds the same names to the same locals (docs/design/SWITCH_CASES.md).
 */
typedef TypedSwitchCase = {
	final arms:Array<TypedSwitchArm>;
	final statements:Array<TypedStatement>;
}

/**
 * The pattern side of a switch arm, shared by statement and expression switches: what the arm matches, what it binds and its
 * guard, with resolved enum bindings when applicable.
 */
typedef TypedSwitchArm = {
	final value:TypedExpression;

	/** The local the matched subject is bound to: `case name:` or the capture `case name = pattern:`. */
	final subjectBinding:Null<String>;

	final arrayPattern:Null<TypedSwitchArrayPattern>;

	/** True when the arm matches every value: the wildcard `_`, or a bare name (which also sets `subjectBinding`). */
	final isCatchAll:Bool;

	final guard:Null<TypedExpression>;
	final enumName:Null<String>;
	final constructorIndex:Int;
	final bindings:Array<TypedSwitchBinding>;
	final predicates:Array<TypedSwitchPredicate>;
	final span:SourceSpan;
}

/** Fixed-length array pattern used by a switch arm, including nested enum patterns. */
typedef TypedSwitchArrayPattern = {
	final elements:Array<TypedSwitchArrayElement>;
}

/** One typed element constraint or binding in a fixed-length array pattern. */
typedef TypedSwitchArrayElement = {
	final type:CompilerType;
	final value:Null<TypedExpression>;

	/** Declared value equality for a value-pattern comparison, if one is required. */
	final equalityFunction:Null<String>;

	final subjectBinding:Null<String>;
	final isCatchAll:Bool;
	final constructorIndex:Int;
	final bindings:Array<TypedSwitchBinding>;
	final predicates:Array<TypedSwitchPredicate>;
}

/** Local binding introduced for one enum-constructor payload position. */
typedef TypedSwitchBinding = {
	final name:String;
	final type:CompilerType;
	final storageType:CompilerType;
	final fieldStorageType:CompilerType;
	final index:Int;
	final arrayIndex:Int;
	final ?nestedPath:Array<TypedSwitchFieldAccess>;
}

/** One enum payload field traversed while matching a nested constructor pattern. */
typedef TypedSwitchFieldAccess = {
	/**
		The enum type of the value whose payload field this access reads. The step before stores that value as its own
		`storageType`, which a recursive generic enum erases (`Node(l:Tree<T>, ...)` keeps `l` as Dynamic), so lowering casts
		the stored value back to this type before reading the field.
	**/
	final enumType:CompilerType;

	final constructorIndex:Int;
	final fieldIndex:Int;
	final storageType:CompilerType;
}

/** One anonymous-object field traversed while matching an enum payload pattern. */
typedef TypedSwitchObjectFieldAccess = {
	final name:String;
	final storageType:CompilerType;
}

/** Constant or structural constraint applied to one enum payload position. */
typedef TypedSwitchPredicate = {
	final value:Null<TypedExpression>;
	final arrayLength:Int;
	final type:CompilerType;
	final storageType:CompilerType;
	final fieldStorageType:CompilerType;
	final index:Int;
	final arrayIndex:Int;
	final ?nestedPath:Array<TypedSwitchFieldAccess>;
	final ?objectPath:Array<TypedSwitchObjectFieldAccess>;
	final ?nestedConstructorIndex:Int;
}

/** Minimal typed information needed to prove constructor coverage across switch arms. */
typedef TypedSwitchCoverageCase = {
	final constructorIndex:Int;
	final subjectBinding:Null<String>;
	final isCatchAll:Bool;
	final guard:Null<TypedExpression>;
	final predicates:Array<TypedSwitchPredicate>;
}

/** Resolved catch arm ready for IR exception lowering. */
typedef TypedCatch = {
	final name:String;
	final type:CompilerType;
	final subject:TypedCatchSubject;
	final statements:Array<TypedStatement>;
	final span:SourceSpan;
}

/**
	The value a catch clause tests and binds, derived from the thrown value as Haxe's exception filter does on HashLink, where
	`throw` throws a value as it is and only the catch wraps or unwraps it.
**/
enum TypedCatchSubject {
	/** `catch (e:Dynamic)` binds the thrown value itself. */
	Thrown;

	/**
		A catch of `haxe.Exception` or a subclass tests and binds `haxe.Exception.caught(thrown)`: the thrown exception, or a
		`haxe.ValueException` wrapping any other value, so `catch (e:haxe.Exception)` catches `throw "x"`.
	**/
	Caught;

	/**
		A catch of any other type tests and binds `haxe.Exception.caught(thrown).unwrap()`: the thrown value, or the value a
		thrown `haxe.ValueException` wraps, so `catch (e:String)` catches `throw new haxe.ValueException("x")`.
	**/
	Unwrapped;
}

/** Resolved enum-constructor signature. */
typedef TypedEnumCase = {
	final name:String;
	final metadata:Array<compiler.syntax.Ast.AstMetadata>;
	final params:Array<CompilerType>;
	final span:SourceSpan;
}

/** Type-checked enum declaration. */
typedef TypedEnum = {
	final name:String;
	final ?specializationOrigin:String;
	final ?specializationArguments:Array<CompilerType>;
	final ?isRecursive:Bool;
	final ?equatable:Bool;
	final ?hashable:Bool;
	final metadata:Array<compiler.syntax.Ast.AstMetadata>;
	final cases:Array<TypedEnumCase>;
	final span:SourceSpan;
}

/** How a typed function relates to the function named by its `origin`. */
enum abstract FunctionOriginKind(String) {
	/** A copy of a generic function for particular type arguments; the origin is the generic function. */
	var Specialization = "specialization";

	/** A lambda; the origin is the function, or lambda, it is written in. */
	var Lambda = "lambda";

	/** A helper made on behalf of a function (an equality, wire codec or closure conversion adapter); the origin is that function. */
	var Helper = "helper";
}

/** The declared role of a typed function, independent of its generated linkage name. */
enum TypedFunctionRole {
	UserFunction;
	GenericFunction;
	LambdaFunction;
	IterationFunction;
	OtherFunction;

	/** A helper that serves `operation` for `subject`; IR generation lowers the subject to a `TypeKey` (see `IrFunctionKind.Provider`). */
	ProviderFunction(subject:CompilerType, operation:compiler.core.Provides.ProviderOperation);
}

/**
 * Fully typed function or method body.
 *
 * Cell maps record mutable storage decisions that IR generation must preserve
 * across closures and exception edges.
 */
typedef TypedFunction = {
	final name:String;
	final role:TypedFunctionRole;

	/**
	 * The function this one is specialized from, written in, or made for. The two are typed, invalidated and kept together:
	 * when `origin` is typed again so is this function, and the module that owns `origin` owns it.
	 */
	final ?origin:String;

	/** Why `origin` is set. */
	final ?originKind:FunctionOriginKind;

	final ?typeArguments:Array<CompilerType>;
	final owner:Null<String>;

	/** Physical receiver owner for a specialized generic instance method. */
	final ?physicalOwner:String;

	final isStatic:Bool;
	final isConstructor:Bool;

	/** Declared `inline`. */
	final ?isInline:Bool;

	/** Declared `@:keep`: backends keep it even when nothing calls it. */
	final ?isKept:Bool;

	/** Declared `@:expose`: kept and exported to the host where the target has one. */
	final ?isExposed:Bool;

	final arguments:Array<{name:String, type:CompilerType}>;
	final result:CompilerType;

	/**
	 * The function's dispatch entry, when it has one (`DefaultArguments`): its method slot and its values hold that entry.
	 * Set on every copy of a method, typed or a signature only, so the slot does not depend on the entry being typed again.
	 */
	final ?dispatchEntry:String;

	final statements:Array<TypedStatement>;
	final cells:Map<String, String>;
	final cellCaptures:Map<String, String>;
	final span:SourceSpan;

	/** Warnings from typing the body, kept with it so a body an incremental compile reuses keeps them. */
	final ?warnings:Array<compiler.core.Diagnostic>;
}

/** Class field after annotation inference and initializer type checking. */
typedef TypedField = {
	final name:String;
	final metadata:Array<compiler.syntax.Ast.AstMetadata>;
	final type:CompilerType;
	final initializer:Null<TypedExpression>;

	/** Evaluated constant retained for compile-time inline-field substitution. */
	final inlineValue:Null<TypedExpression>;

	final ?isDynamicMethod:Bool;

	final readAccess:Null<compiler.syntax.Ast.AstFieldAccess>;
	final writeAccess:Null<compiler.syntax.Ast.AstFieldAccess>;
	final isStatic:Bool;
	final isInline:Bool;
	final isFinal:Bool;
	final span:SourceSpan;

	/** Warnings from typing the initializer, kept as a function body's are. */
	final ?warnings:Array<compiler.core.Diagnostic>;
}

/** Class declaration with resolved field, method, and inheritance contracts. */
typedef TypedClass = {
	final name:String;

	/** Type parameter names on the source generic declaration. */
	final ?genericParameters:Array<String>;

	/** Source declaration and representation arguments for a specialized generic owner. */
	final ?specializationOrigin:String;

	final ?specializationArguments:Array<CompilerType>;
	final isValue:Bool;
	final isFlat:Bool;
	final isPortable:Bool;

	/** C-layout record with no HashLink object or value-structure representation. */
	final isNativeValue:Bool;

	/** Portable and selected-target layouts retained for compile-time layout queries. */
	final nativeLayouts:Array<TypedNativeLayout>;

	final base:Null<String>;
	final interfaces:Array<String>;
	final fields:Array<TypedField>;
	final methods:Array<TypedFunction>;
	final span:SourceSpan;
}

/** Computed layout for one portable target ABI. */
typedef TypedNativeLayout = {
	final target:String;
	final size:Int;
	final alignment:Int;
	final fields:Array<TypedNativeFieldLayout>;
}

/** Byte placement of one field in a native record. */
typedef TypedNativeFieldLayout = {
	final name:String;
	final offset:Int;
	final size:Int;
	final alignment:Int;
}

/** Resolved callable contract required by an interface. */
typedef TypedInterfaceMethod = {
	final name:String;
	final arguments:Array<CompilerType>;
	final result:CompilerType;
}

/** Interface declaration after base and method signature resolution. */
typedef TypedInterface = {
	final name:String;
	final bases:Array<String>;
	final methods:Array<TypedInterfaceMethod>;
}

/** Reason a local is represented by a shared generated cell. */
enum CellStorageKind {
	MutableCapture;
	ExceptionEdge;
}

/** Storage location read while constructing a closure environment. */
enum TypedCaptureSource {
	CaptureLocal(bindingId:String);
	CaptureReceiver;
	CaptureCellLocal(name:String, cellClass:String);
	CaptureEnvironmentField(name:String);
	CaptureCellEnvironmentField(name:String, cellClass:String);
	CaptureExpression(expression:TypedExpression);
}

/** Stored fields to copy for a value class, with the layout of nested mutable value classes that need copying too. */
typedef ValueCopyLayout = {
	final name:String;
	final fields:Array<{name:String, type:CompilerType, nested:Null<ValueCopyLayout>}>;
}

/** A closure capture tied to its resolved lexical binding and storage source. */
typedef TypedCapture = {
	final field:String;
	final bindingId:String;
	final type:CompilerType;
	final storageType:CompilerType;
	final source:TypedCaptureSource;
}

/** Semantic storage required to preserve a binding across an exceptional edge or closure. */
typedef TypedStorageRequirement = {
	final name:String;
	final valueType:CompilerType;
	final kind:CellStorageKind;
}

/** Semantic captures shared by one generated lambda body. */
typedef TypedEnvironmentRequirement = {
	final name:String;
	final captures:Array<TypedCapture>;
}

/** Closure and exceptional-edge requirements consumed by lowering. */
typedef TypedClosurePlan = {
	final storage:Array<TypedStorageRequirement>;
	final environments:Array<TypedEnvironmentRequirement>;
}

/** Named backend representation of a structural anonymous type. */
typedef TypedAnonymous = {
	final name:String;
	final fields:Array<compiler.types.Type.AnonymousField>;
}

/** Complete semantic module consumed by IR generation. */
typedef TypedProgram = {
	final nativeAbiTarget:String;

	/** Semantic generic instances mapped to their physical specialized owners. */
	final genericOwnerAliases:Map<String, String>;

	final nativeTypeDescriptors:Array<compiler.types.NativeTypeDescriptor.NativeTypeDescriptorData>;
	final enums:Array<TypedEnum>;
	final interfaces:Array<TypedInterface>;
	final classes:Array<TypedClass>;
	final functions:Array<TypedFunction>;
	final closurePlan:TypedClosurePlan;
	final anonymousTypes:Array<TypedAnonymous>;

	final natives:Array<TypedNative>;

	/** The locals of the bodies this compile typed whose type nothing fixed, so it settled to Dynamic, as in Haxe. */
	final unboundLocals:Array<UnboundLocal>;

	/** The `throw`s of the bodies this compile typed whose value is not statically a haxe.Exception. */
	final nonExceptionThrows:Array<NonExceptionThrow>;

	/**
	 * The lambdas of the bodies this compile typed whose block ends in an expression (`LambdaTrailingValue`), when
	 * `CompileOptions.lambdaTrailingValues` asks for them; empty otherwise.
	 */
	final lambdaTrailingValues:Array<LambdaTrailingValue>;
}

/**
 * A local whose type, or part of it, nothing fixed (`var x;` never assigned, `var list = []` never used with a type), so it settled
 * to Dynamic (`BodyTyper.settleFrame`). Haxe gives no warning, and neither does the compiler: `haxeon lint --only unbound-local`
 * names them.
 */
typedef UnboundLocal = {
	final name:String;

	/** The local's declaration. */
	final span:SourceSpan;

	/** What settled: `the type of local "x"`, `the element type of this empty array`. */
	final what:String;
}

/**
 * A `throw` whose value's static type is not haxe.Exception or a subclass of it (a String, Dynamic, an enum), so a catch of
 * haxe.Exception sees it wrapped in a ValueException. Haxe accepts it, and so does the compiler: `haxeon lint --only
 * throw-non-exception` names them, for code that keeps to throwing exceptions.
 */
typedef NonExceptionThrow = {
	/** The `throw`. */
	final span:SourceSpan;

	/** The thrown value's static type, as a diagnostic writes it. */
	final thrown:String;
}

/**
 * A lambda whose block ends in an expression, typed once: an arrow's block returns that value, where a `function` lambda's drops
 * it. The two forms agree when the lambda's type returns Void, which drops it either way, or when the value is itself Void.
 * `haxeon lint --fix` writes a `function` lambda as an arrow on this evidence (FunctionLambdas), when every typing of it agrees.
 */
typedef LambdaTrailingValue = {
	/** The lambda, from its `function` or its parameters. */
	final span:SourceSpan;

	/** Whether the arrow form means the same in this typing: its type returns Void, or the last expression is Void. */
	final arrowAgrees:Bool;
}

/** A source-declared target function with no generated body. */
typedef TypedNative = {
	final name:String;
	final library:String;
	final symbol:String;
	final arguments:Array<CompilerType>;
	final result:CompilerType;
	final convention:NativeConvention;
}

enum NativeConvention {
	HashLinkNative;
	CNative(signature:String);
}
