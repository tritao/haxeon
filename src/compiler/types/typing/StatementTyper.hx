package compiler.types.typing;

import compiler.core.Diagnostic;
import compiler.core.Diagnostic.CompileError;
import compiler.core.Source.SourceSpan;
import compiler.runtime.PlatformAbi;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstCatch;
import compiler.syntax.Ast.AstStatement;
import compiler.syntax.Ast.AstSwitchCase;
import compiler.syntax.Ast.AstType;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;
import compiler.types.analysis.AstScan;
import compiler.types.analysis.ControlFlow;
import compiler.types.analysis.FlowAnalysis;
import compiler.types.analysis.LexicalStorageAnalysis;
import compiler.types.TypeRelations;
import compiler.types.IterationProtocol;
import compiler.types.analysis.Scope;
import compiler.types.analysis.Scope.LocalFunction;
import compiler.types.TypedAst.TypedCatch;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedStatement;
import compiler.types.TypedAst.TypedSwitchBinding;
import compiler.types.TypedAst.TypedSwitchCase;
import compiler.types.TypedAst.TypedSwitchPredicate;
import compiler.types.TypedAst.TypedSwitchCoverageCase;

typedef StatementExpressionCallback = (AstExpression, Scope, Null<CompilerType>, Bool) -> TypedExpression;
typedef StatementCoerceCallback = (TypedExpression, CompilerType, String, String) -> TypedExpression;
typedef ExpectedInitializerCallback = (String, AstExpression) -> Null<CompilerType>;

/** The type of the first assignment to a local, typed with the locals declared on the way to it. */
typedef BindCellCallback = (String, SourceSpan, Scope, CompilerType) -> Void;
typedef TypeStatementsCallback = (Array<AstStatement>, Scope, Null<CompilerType>) -> Array<TypedStatement>;
typedef ExhaustiveEnumCallback = (CompilerType, Array<TypedSwitchCase>) -> Bool;
typedef LowerTypeCallback = (type:AstType, span:SourceSpan) -> CompilerType;
typedef NullableUnwrapper = TypedExpression->TypedExpression;
typedef MapKeyIteratorSource = TypedExpression->Null<TypedExpression>;

typedef StaticFieldInfo = {owner:String, type:CompilerType};

typedef AssignmentTypingRules = {
	findStaticField:(String, String) -> Null<StaticFieldInfo>,
	requireStaticField:(String, String, SourceSpan) -> StaticFieldInfo,
	rejectInlineFieldMutation:(String, String, SourceSpan) -> Void,
	findFieldType:(CompilerType, String) -> Null<CompilerType>,
	instancePropertyAccessor:(CompilerType, String, Bool) -> Null<String>,
	propertySetterCall:(TypedExpression, String, TypedExpression, SourceSpan) -> TypedExpression,
	fieldType:(CompilerType, String, SourceSpan) -> CompilerType,
	fieldRepresentationType:(CompilerType, String, SourceSpan) -> CompilerType,
	abiBoundaryCast:(TypedExpression, CompilerType) -> TypedExpression,
	arrayElementType:(CompilerType, SourceSpan) -> CompilerType,
	boundCell:(String, Scope) -> Null<String>
};

/** Types declarations, exits, and structured control flow within a body context. */
class StatementTyper {
	final session:TypingSession;
	final typeExpression:StatementExpressionCallback;
	final coerce:StatementCoerceCallback;
	final expectedInitializerType:ExpectedInitializerCallback;
	final bindCell:BindCellCallback;
	final typeStatements:TypeStatementsCallback;
	final exhaustiveEnum:ExhaustiveEnumCallback;
	final lowerType:LowerTypeCallback;
	final unwrapNullable:NullableUnwrapper;
	final mapKeyIteratorSource:MapKeyIteratorSource;
	final switchRules:SwitchTypingRules;
	final assignmentRules:AssignmentTypingRules;

	public function new(session:TypingSession, typeExpression:StatementExpressionCallback,
			coerce:StatementCoerceCallback,
			expectedInitializerType:ExpectedInitializerCallback, bindCell:BindCellCallback,
			typeStatements:TypeStatementsCallback,
			exhaustiveEnum:ExhaustiveEnumCallback, lowerType:LowerTypeCallback, unwrapNullable:NullableUnwrapper,
			mapKeyIteratorSource:MapKeyIteratorSource,
			switchRules:SwitchTypingRules, assignmentRules:AssignmentTypingRules) {
		this.session = session;
		this.typeExpression = typeExpression;
		this.coerce = coerce;
		this.expectedInitializerType = expectedInitializerType;
		this.bindCell = bindCell;
		this.typeStatements = typeStatements;
		this.exhaustiveEnum = exhaustiveEnum;
		this.lowerType = lowerType;
		this.unwrapNullable = unwrapNullable;
		this.mapKeyIteratorSource = mapKeyIteratorSource;
		this.switchRules = switchRules;
		this.assignmentRules = assignmentRules;
	}

	/**
	 * A local initialized with a reference to a declared function and never reassigned is that function: calls
	 * through it may omit the optional arguments and take the defaults, as calls to the function itself do. The
	 * function type alone cannot say which arguments are optional.
	 */
	function aliasedFunction(name:String, span:SourceSpan, value:TypedExpression, statements:Array<AstStatement>,
			statementIndex:Int,
			scope:Scope):Null<LocalFunction> {
		var referenced = switch value.expression {
			case TFunctionRef(target): target;
			default: return null;
		};
		var signature = session.signatures.get(referenced);
		if (signature == null || (signature.typeParameters != null && signature.typeParameters.length > 0))
			return null;
		var hasOptional = false;
		for (argument in signature.arguments)
			if (argument.optional == true || argument.defaultValue != null)
				hasOptional = true;
		if (!hasOptional)
			return null;
		// A local can only be written in its scope, which the body's assigned declarations already cover.
		if (session.currentContext.assignedDeclarations.exists(LexicalStorageAnalysis.key(name, span)))
			return null;
		return {
			arguments: signature.arguments,
			body: [],
			outerLocals: scope.visibleLocalNames(),
			declaredIn: scope
		};
	}

	/**
	 * The type of `var name;`: the one its block is expected to have, for a block expression's result local; otherwise a type
	 * variable its first assignment fills (`Monomorphs`), hinted by what a later use expects.
	 */
	function uninitializedType(name:String, span:SourceSpan):CompilerType {
		var context = session.currentContext,
			result = context.resultLocalTypes.get(name);
		if (result != null)
			return result;
		var expected = context.localExpectedTypes.get(name),
			variable = session.monomorphs.create('the type of local "$name"', span);
		if (variable != null) {
			if (expected != null)
				compiler.types.Monomorphs.hint(variable, expected);
			return variable;
		}
		if (expected != null)
			return expected;
		throw new CompileError(new Diagnostic("E1002", 'Cannot infer type of local "$name"; add a type annotation',
			span));
	}

	public function typeSimpleStatement(statement:AstStatement, scope:Scope, result:Null<CompilerType>,
			statements:Array<AstStatement>,
			statementIndex:Int):Null<Array<TypedStatement>> {
		var context = session.currentContext;
		return switch statement {
			case ErrorStatement(_): [];
			case UninitializedDeclaration(name, declared, span):
				var declaredType = (switch (declared) {
					case InferredType: true;
					default: false;
				}) ? uninitializedType(name, span) : session.declarations.resolve(declared, null,
					context.typeSubstitutions);
				scope.define(name, declaredType, span, false);
				bindCell(name, span, scope, declaredType);
				[TDeclare(scope.requireId(name), declaredType, span)];
			case VarDeclaration(name, declared, initializer, span):
				var localFunction:Null<LocalFunction> = null;
				// A lambda with a declared result type is bound through a typed local; look through that wrapper.
				var lambda = initializer;
				switch initializer {
					case BlockExpression(wrapper, Variable(_, _), _) if (wrapper.length == 1):
						switch wrapper[0] {
							case VarDeclaration(_, _, wrapped, _): lambda = wrapped;
							default:
						}
					default:
				}
				switch lambda {
					case Lambda(arguments, body, _, _):
						// Its writes, in its own body or after it, are in the body's assigned declarations.
						if (!context.assignedDeclarations.exists(LexicalStorageAnalysis.key(name, span)))
							localFunction = {
								arguments: arguments,
								body: body,
								outerLocals: scope.visibleLocalNames(),
								declaredIn: scope
							};
					default:
				}
				var declaredType:Null<CompilerType> = declared == null ? expectedInitializerType(name,
					initializer) : session.declarations.resolve(declared, null, context.typeSubstitutions);
				var predeclared = false, recursiveCell:Null<String> = null;
				if (declaredType != null)
					switch initializer {
						case Lambda(_, _, _, _):
							scope.define(name, declaredType, span, true, null, false, localFunction);
							predeclared = true;
							// A recursive local function reads itself through a cell bound before its closure exists.
							bindCell(name, span, scope, declaredType);
							recursiveCell = context.storage.cell(scope.requireId(name));
						default:
					}
				var value = typeExpression(initializer, scope, declaredType, false);
				// `var x = null` is a `Null<?>` whose `?` the first assignment of a value fills (`Monomorphs`).
				if (declaredType == null && TypeRelations.equals(value.type, TNull)) {
					var variable = session.monomorphs.create('the type of local "$name"', span);
					if (variable != null)
						declaredType = TNullable(variable);
				}
				// What a later use expects of a local whose initializer made a type variable is that variable's hint.
				var laterUse = declared == null ? context.localExpectedTypes.get(name) : null;
				if (laterUse != null)
					compiler.types.Monomorphs.hint(declaredType != null ? declaredType : value.type, laterUse);
				if (declaredType != null)
					value = coerce(value, declaredType, 'local "$name"', "E1002");
				else
					value = ValueCopy.bind(session, value, value.type);
				if (recursiveCell != null)
					return [
						TDeclare(scope.requireId(name), declaredType, span),
						TCellAssign(scope.requireId(name), recursiveCell, value, span)
					];
				else if (TypeRelations.equals(value.type, TNull))
					fail("E1002", 'Null requires an explicit nullable type for local "$name"', span);
				if (localFunction == null && declared == null)
					localFunction = aliasedFunction(name, span, value, statements, statementIndex, scope);
				if (!predeclared)
					scope.define(name, value.type, span, true, null, false, localFunction);
				var pathConstant = KeyPathTyping.known(session, value);
				if (pathConstant != null
					&& !context.assignedDeclarations.exists(compiler.types.analysis.BindingWalker.key(name, span))) {
					scope.setKeyPathConstant(name, pathConstant.name);
					return [];
				}
				scope.setMapKeySource(name, value.mapKeySource);
				// A local never reassigned holds its initializer: a constructor without arguments is then known by value.
				var constructor = switch value.expression {
					case TEnumLiteral(_, index): index;
					case TEnumConstruct(_, index, arguments) if (arguments.length == 0): index;
					default: -1;
				};
				if (constructor >= 0
					&& !context.assignedDeclarations.exists(compiler.types.analysis.BindingWalker.key(name, span)))
					scope.setKnownConstructor(name, constructor);
				bindCell(name, span, scope, value.type);
				[TVar(scope.requireId(name), value, span)];
			case Return(expression, span):
				var expected = result == null ? context.inferredResult : result;
				var value = typeExpression(expression, scope, expected, false),
					output:Array<TypedStatement> = [];
				var thrown = switch value.expression {
					case TThrowExpression(thrown): thrown;
					default: null;
				};
				if (thrown != null) {
					// `return throw e`, and an expression-bodied lambda whose body throws,
					// never produce a value: a throw statement, which leaves the function's
					// result to its other returns (or Void) instead of inferring Never.
					output.push(TThrow(thrown, span));
				} else if (expected == null && (switch (value.type) {
					case TNever: true;
					default: false;
				})) {
					// Likewise a call that never returns, such as the body of `try fail() catch (e:String) 40`.
					output.push(TExpression(value, span));
				} else if (expected != null && (switch (expected) {
					case TVoid: true;
					default: false;
				}) && context.contextualVoidLambda) {
					output.push(TExpression(value, span));
					output.push(TReturnVoid(span));
				} else {
					if (expected == null)
						context.inferredResult = value.type;
					else
						value = coerce(value, expected, "return", "E1003");
					output.push(TReturn(value, span));
				}
				output;
			case ReturnVoid(span):
				var expected = result == null ? context.inferredResult : result;
				if (expected == null)
					context.inferredResult = TVoid;
				else if ((switch (expected) {
					case TVoid: false;
					default: true;
				}))
					fail("E1003", "Return type mismatch", span);
				[TReturnVoid(span)];
			case Throw(expression, span):
				var value = typeExpression(expression, scope, null, false);
				if (TypeRelations.equals(value.type, TVoid))
					fail("E1021", "Cannot throw a Void value", span);
				if (TypeRelations.equals(value.type, TNull))
					fail("E1021", "Cannot throw null", span);
				[TThrow(value, span)];
			case Break(span):
				if (context.loopDepth == 0)
					fail("E1017", "break is only valid inside a loop", span);
				[TBreak(span)];
			case Continue(span):
				if (context.loopDepth == 0)
					fail("E1017", "continue is only valid inside a loop", span);
				[TContinue(span)];
			case Expression(expression, span):
				[TExpression(typeExpression(expression, scope, (switch (result) {
					case TVoid: true;
					default: false;
				})
					|| context.contextualVoidLambda ? TVoid : null, false), span)];
			default: null;
		};
	}

	public function typeIncrement(name:String, delta:Int, span:SourceSpan, scope:Scope):TypedStatement {
		name = sourceTarget(name, span, scope);
		if (scope.isScoped(name))
			fail("E1002", 'Cannot reassign scoped binding "$name"', span);
		var current = scope.resolve(name);
		// A Dynamic local, or a field of one, is incremented as `target = target + 1` with the Dynamic operators, and a nullable
		// number the same way, reading null as 0 as Haxe does.
		var dot = name.indexOf("."),
			root = dot < 0 ? null : scope.resolve(name.substring(0, dot));
		// The stored type decides, not a narrowed one: a `Null<Int>` incremented once reads as an Int but still holds a Null<Int>.
		if ((current != null
			&& (sameType(current, TDynamic) || ExpressionTyper.isNullableNumber(scope.resolveDeclared(name))))
			|| (current == null && root != null && sameType(root, TDynamic))) {
			// Adding keeps an Int an Int; subtracting would give a Float, as `target -= 1` does.
			var step = delta > 0 ? IntegerLiteral(1, span) : Negate(IntegerLiteral(1, span), span);
			return typeAssignment(name, Add(Variable(name, span), step, span), span, scope);
		}
		if (current != null && !scope.isAssigned(name))
			fail("E1023", 'Local "$name" may be used before assignment', span);
		if (current == null) {
			var dot = name.indexOf("."),
				owner = dot < 0 ? session.currentContext.lexicalOwner : name.substring(0, dot),
				fieldName = dot < 0 ? name : name.substring(dot + 1, name.length),
				staticField:Null<StaticFieldInfo> = null;
			if (owner != null)
				staticField = assignmentRules.findStaticField(owner, fieldName);
			if (staticField != null && ExpressionTyper.isNullableNumber(staticField.type)) {
				var step = delta > 0 ? IntegerLiteral(1, span) : Negate(IntegerLiteral(1, span), span);
				return typeAssignment(name, Add(Variable(name, span), step, span), span, scope);
			}
			if (staticField == null || (!sameType(staticField.type, TInt) && !sameType(staticField.type, TFloat)))
				fail("E1018", 'Increment requires a numeric local or static field "$name"', span);
			assignmentRules.rejectInlineFieldMutation(staticField.owner, fieldName, span);
			FinalFieldRules.rejectStaticMutation(session, staticField.owner, fieldName, span);
			var oldValue = new TypedExpression(TStaticField(staticField.owner, fieldName), staticField.type, span),
				one:TypedExpression = sameType(staticField.type,
					TInt) ? new TypedExpression(TIntLiteral(1), TInt, span) : new TypedExpression(TFloatLiteral(1.0),
					TFloat, span),
				updated = delta > 0 ? new TypedExpression(TAdd(oldValue, one), staticField.type,
					span) : new TypedExpression(TSub(oldValue, one), staticField.type, span);
			scope.invalidateExpression('static:${staticField.owner}.$fieldName');
			return TStaticFieldAssign(staticField.owner, fieldName, updated, span);
		}
		if (!sameType(current, TInt) && !sameType(current, TFloat))
			fail("E1018", 'Increment requires a numeric local "$name"', span);
		scope.invalidateExpressionsForLocal(name);
		if (scope.isCapture(name)) {
			if (!scope.isCellCapture(name))
				fail("E1013", 'Captured variable "$name" requires mutable capture cells', span);
			return TCellCapturedIncrement(name, scope.requireCellClass(name), current, delta, span);
		}
		var cell = assignmentRules.boundCell(name, scope);
		return cell != null ? TCellIncrement(scope.requireId(name), cell, current, delta,
			span) : TIncrement(scope.requireId(name), delta, span);
	}

	/**
	 * A bare assignment target that names a module-level variable arrives qualified, with its source name on the span (see
	 * ModuleCanonicalizer.targetSpan). As for a read, the source name wins when it names a local, a member of `this` or a static
	 * of the enclosing class.
	 */
	function sourceTarget(name:String, span:SourceSpan, scope:Scope):String {
		var source = span.isBareReference ? span.referenceName : null;
		if (source == null || source == name || source.indexOf(".") >= 0)
			return name;
		if (scope.resolve(source) != null)
			return source;
		var thisType = scope.resolve("this"), owner = session.currentContext.lexicalOwner;
		if (thisType != null && assignmentRules.findFieldType(thisType, source) != null
			|| owner != null && assignmentRules.findStaticField(owner, source) != null)
			return source;
		return name;
	}

	public function typeAssignment(name:String, expression:AstExpression, span:SourceSpan, scope:Scope):TypedStatement {
		name = sourceTarget(name, span, scope);
		var dot = name.lastIndexOf(".");
		if (dot < 0) {
			if (scope.isScoped(name))
				fail("E1002", 'Cannot reassign scoped binding "$name"', span);
			var expected = scope.resolveDeclared(name);
			if (expected == null) {
				var thisType = scope.resolve("this"),
					instanceField = thisType == null ? null : assignmentRules.findFieldType(thisType, name);
				if (instanceField != null) {
					if (thisType == null)
						throw 'Missing "this" type for field "$name"';
					var assignedValue = typeExpression(expression, scope, instanceField, false),
						value = coerce(assignedValue, instanceField, 'field "$name"', "E1002");
					var receiver = typeExpression(Variable("this", span), scope, null, false),
						propertySetter = assignmentRules.instancePropertyAccessor(thisType, name, false);
					if (propertySetter != null) {
						session.invalidateCallEffects(propertySetter, scope);
						return TExpression(assignmentRules.propertySetterCall(receiver, propertySetter, value, span),
							span);
					}
					var receiverPath = FlowAnalysis.accessPath(receiver);
					scope.invalidateField(name);
					if (receiverPath != null) {
						var fieldPath = receiverPath + "." + name;
						scope.invalidateExpression(fieldPath);
						scope.refineExpression(fieldPath, assignmentFlowType(assignedValue.type, instanceField));
					}
					return TFieldAssign(receiver, name, assignmentRules.abiBoundaryCast(value,
						assignmentRules.fieldRepresentationType(thisType, name, span)),
						span);
				}
				var owner = session.currentContext.lexicalOwner,
					staticField:Null<StaticFieldInfo> = null;
				if (owner != null)
					staticField = assignmentRules.findStaticField(owner, name);
				if (staticField == null)
					fail("E1005", 'Unknown variable "$name"', span);
				assignmentRules.rejectInlineFieldMutation(staticField.owner, name, span);
				var assignedValue = typeExpression(expression, scope, staticField.type, false),
					value = coerce(assignedValue, staticField.type, 'field "$name"', "E1002");
				refineStaticStore(scope, staticField.owner, name, assignedValue.type, staticField.type);
				return TStaticFieldAssign(staticField.owner, name, value, span);
			}
			var assignedValue = typeExpression(expression, scope, expected, false),
				value = coerce(assignedValue, expected, 'local "$name"', "E1002"),
				statement:TypedStatement;
			if (scope.isCapture(name)) {
				if (!scope.isCellCapture(name))
					fail("E1013", 'Captured variable "$name" requires mutable capture cells', span);
				statement = TCellCapturedAssign(name, scope.requireCellClass(name), value, span);
			} else {
				var cell = assignmentRules.boundCell(name, scope);
				statement = cell != null ? TCellAssign(scope.requireId(name), cell, value,
					span) : TAssign(scope.requireId(name), value, span);
			}
			scope.markAssigned(name);
			scope.setMapKeySource(name, value.mapKeySource);
			scope.invalidateExpressionsForLocal(name);
			var flowType = assignmentFlowType(assignedValue.type, value.type);
			scope.recordAssignment(name, flowType);
			scope.refine(name, flowType);
			return statement;
		}

		var objectName = name.substring(0, dot),
			fieldName = name.substring(dot + 1, name.length),
			object = unwrapNullable(typeExpression(Variable(objectName, span), scope, null, false));
		if (sameType(object.type, TDynamic))
			return dynamicFieldAssignment(object, fieldName, expression, span, scope);
		rejectFinalAnonymousFieldMutation(object.type, fieldName, span);
		FinalFieldRules.rejectInstanceMutation(session, object, fieldName, span);
		ValuePlaceRules.requireWritable(session, object, span);
		return switch object.expression {
			case TClassRef(className):
				var staticField = assignmentRules.requireStaticField(className, fieldName, span);
				assignmentRules.rejectInlineFieldMutation(staticField.owner, fieldName, span);
				FinalFieldRules.rejectStaticMutation(session, staticField.owner, fieldName, span);
				var assignedValue = typeExpression(expression, scope, staticField.type, false),
					value = coerce(assignedValue, staticField.type, 'field "$name"', "E1002");
				refineStaticStore(scope, staticField.owner, fieldName, assignedValue.type, staticField.type);
				TStaticFieldAssign(staticField.owner, fieldName, value, span);
			default:
				var platformField = PlatformAbi.field(object.type, fieldName),
					expected = assignmentRules.fieldType(object.type, fieldName, span),
					assignedValue = typeExpression(expression, scope, expected, false),
					value = coerce(assignedValue, expected, 'field "$name"', "E1002"),
					setter:Null<String> = platformField == null ? null : platformField.set,
					propertySetter = setter == null ? assignmentRules.instancePropertyAccessor(object.type, fieldName,
						false) : null,
					statement = if (setter != null) TExpression(new TypedExpression(TCall(setter, [object, value]),
						TVoid, span), span) else {
							propertySetter != null ? TExpression(assignmentRules.propertySetterCall(object,
								propertySetter, value, span), span) : {value = assignmentRules.abiBoundaryCast(value,
								assignmentRules.fieldRepresentationType(object.type, fieldName, span));
							TFieldAssign(object, fieldName, value, span);
							};
						};
				if (setter != null) session.invalidateUnknownCall(scope);
				else if (propertySetter != null) session.invalidateCallEffects(propertySetter, scope);
				scope.invalidateField(fieldName);
				var objectPath = FlowAnalysis.accessPath(object);
				if (objectPath != null && setter == null && propertySetter == null) {
					var fieldPath = objectPath + "." + fieldName;
					scope.invalidateExpression(fieldPath);
					scope.refineExpression(fieldPath, assignmentFlowType(assignedValue.type, expected));
				}
				statement;
		};
	}

	public function typeIndexAssignment(array:AstExpression, offset:AstExpression, expression:AstExpression,
			span:SourceSpan, scope:Scope):TypedStatement {
		var typedArray = unwrapNullable(typeExpression(array, scope, null, false)),
			typedIndex = typeExpression(offset, scope, null, false);
		return switch typedArray.type {
			case TMap(key, mapValue):
				DeclaredConformance.requireMapRuntime(session, key, mapValue, span);
				typedIndex = coerce(typedIndex, key, "map key", "E1002");
				var value = coerce(typeExpression(expression, scope, mapValue, false), mapValue, "map value", "E1002"),
					entryPath = FlowAnalysis.mapEntryPath(typedArray, typedIndex);
				if (entryPath != null)
					scope.refineExpression(entryPath, mapValue, FlowAnalysis.entryFactsSurviveCalls(scope, typedArray));
				TMapAssign(typedArray, typedIndex, value, span);
			default:
				typedIndex = ConversionResolver.plainValue(typedIndex, coerce);
				if ((switch typedIndex.type {
					case TNever: true;
					case TAbstract(_, _, _): session.relations.isAssignable(typedIndex.type, TInt);
					default: false;
				}))
					typedIndex = coerce(typedIndex, TInt, "array index", "E1014");
				if ((switch (typedIndex.type) {
					case TInt: false;
					default: true;
				}))
					fail("E1014", "Array index must be Int", typedIndex.span);
				var element = assignmentRules.arrayElementType(typedArray.type, span),
					value = coerce(typeExpression(expression, scope, element, false), element, "array element",
						"E1002");
				// A stored value can replace any literal-index element reached through an alias.
				// Drop these transient refinements globally rather than retaining an unsound path fact.
				scope.invalidateExpressionNamespace("array-entry:");
				TIndexAssign(typedArray, typedIndex, value, span);
		};
	}

	/** `dynamicValue.field = value`: the field is set when the program runs, and the value is boxed. */
	function dynamicFieldAssignment(object:TypedExpression, fieldName:String, expression:AstExpression, span:SourceSpan,
			scope:Scope):TypedStatement {
		var value = typeExpression(expression, scope, null, false);
		scope.invalidateField(fieldName);
		return dynamicFieldStore(object, fieldName, value, span);
	}

	function dynamicFieldStore(object:TypedExpression, fieldName:String, value:TypedExpression,
			span:SourceSpan):TypedStatement {
		session.runtimeDependencyTracker.record(session.currentContext.name, "Reflect");
		var boxed = coerce(value, TDynamic, 'field "$fieldName"', "E1002"),
			call = new TypedExpression(TCall("Reflect.setField", [
				object,
				new TypedExpression(TStringLiteral(fieldName), TString, span),
				boxed
			]), TVoid, span);
		return TExpression(call, span);
	}

	public function typeFieldAssignment(receiverExpression:AstExpression, fieldName:String, expression:AstExpression,
			span:SourceSpan,
			scope:Scope):TypedStatement {
		var object = unwrapNullable(typeExpression(receiverExpression, scope, null, false));
		if (sameType(object.type, TDynamic))
			return dynamicFieldAssignment(object, fieldName, expression, span, scope);
		rejectFinalAnonymousFieldMutation(object.type, fieldName, span);
		FinalFieldRules.rejectInstanceMutation(session, object, fieldName, span);
		ValuePlaceRules.requireWritable(session, object, span);
		return switch object.expression {
			case TClassRef(className):
				var staticField = assignmentRules.requireStaticField(className, fieldName, span);
				assignmentRules.rejectInlineFieldMutation(staticField.owner, fieldName, span);
				FinalFieldRules.rejectStaticMutation(session, staticField.owner, fieldName, span);
				var assignedValue = typeExpression(expression, scope, staticField.type, false),
					value = coerce(assignedValue, staticField.type, 'field "$fieldName"', "E1002");
				refineStaticStore(scope, staticField.owner, fieldName, assignedValue.type, staticField.type);
				TStaticFieldAssign(staticField.owner, fieldName, value, span);
			default:
				var platformField = PlatformAbi.field(object.type, fieldName),
					expected = assignmentRules.fieldType(object.type, fieldName, span),
					assignedValue = typeExpression(expression, scope, expected, false),
					value = coerce(assignedValue, expected, 'field "$fieldName"', "E1002");
				var setter:Null<String> = platformField == null ? null : platformField.set,
					propertySetter = setter == null ? assignmentRules.instancePropertyAccessor(object.type, fieldName,
						false) : null;
				var statement = if (setter != null) TExpression(new TypedExpression(TCall(setter, [object, value]),
					TVoid, span), span) else {
						if (propertySetter != null)
							TExpression(assignmentRules.propertySetterCall(object, propertySetter, value, span), span)
								else {
								value = assignmentRules.abiBoundaryCast(value,
									assignmentRules.fieldRepresentationType(object.type, fieldName, span));
								TFieldAssign(object, fieldName, value, span);
							}
					};
				if (setter != null) session.invalidateUnknownCall(scope);
				else if (propertySetter != null) session.invalidateCallEffects(propertySetter, scope);
				scope.invalidateField(fieldName);
				var objectPath = FlowAnalysis.accessPath(object);
				if (objectPath != null && setter == null && propertySetter == null) {
					var fieldPath = objectPath + "." + fieldName;
					scope.invalidateExpression(fieldPath);
					scope.refineExpression(fieldPath, assignmentFlowType(assignedValue.type, expected));
				}
				statement;
		};
	}

	/** A store to a static field replaces what earlier null checks said about it, and about anything reached through it. */
	static function refineStaticStore(scope:Scope, owner:String, name:String, assigned:CompilerType,
			stored:CompilerType):Void {
		var path = 'static:$owner.$name';
		scope.invalidateExpression(path);
		scope.refineExpression(path, assignmentFlowType(assigned, stored));
	}

	static function assignmentFlowType(source:CompilerType, stored:CompilerType):CompilerType
		return switch source {
			case TNull, TNullable(_), TDynamic: stored;
			default: switch stored {
					case TNullable(element): element;
					default: stored;
				}
		};

	static function sameType(left:CompilerType, right:CompilerType):Bool
		return TypeRelations.equals(left, right);

	public function typeTry(tryBranch:Array<AstStatement>, catches:Array<AstCatch>, span:SourceSpan, scope:Scope,
			result:Null<CompilerType>):TypedStatement {
		var typedCatches:Array<TypedCatch> = [],
			catchScopes:Array<Scope> = [],
			tryScope = new Scope(scope),
			exceptionalInvalidations = tryScope.trackInvalidations(),
			typedTry = typeStatements(tryBranch, tryScope, result);
		for (i in 0...catches.length) {
			var catchClause = catches[i],
				loweredCatchType = lowerType(catchClause.type, catchClause.span);
			switch loweredCatchType {
				case TDynamic:
					if (i != catches.length - 1)
						fail("E1022", "Dynamic catch must be the final catch clause", catchClause.span);
				case TInt, TFloat, TBool, TString:
				case TInstance(kind, _, arguments):
					if (Std.string(kind) != "class" && Std.string(kind) != "interface" && Std.string(kind) != "enum")
						fail("E1022", "Unsupported catch binding type", catchClause.span);
					if (arguments.length != 0)
						fail("E1022", "Unsupported generic catch binding type", catchClause.span);
				default:
					fail("E1022", "Unsupported catch binding type", catchClause.span);
			}
			var catchScope = new Scope(scope);
			// A handler can run after any prefix of the try body, not just after its final state.
			catchScope.applyInvalidations(exceptionalInvalidations);
			catchScopes.push(catchScope);
			catchScope.define(catchClause.name, loweredCatchType, catchClause.span);
			bindCell(catchClause.name, catchClause.span, catchScope, loweredCatchType);
			typedCatches.push({
				name: catchScope.requireId(catchClause.name),
				type: loweredCatchType,
				statements: typeStatements(catchClause.statements, catchScope, result),
				span: catchClause.span
			});
		}
		var continuing:Array<Scope> = [];
		if (!ControlFlow.alwaysExits(typedTry, exhaustiveEnum))
			continuing.push(tryScope);
		for (i in 0...typedCatches.length)
			if (!ControlFlow.alwaysExits(typedCatches[i].statements, exhaustiveEnum))
				continuing.push(catchScopes[i]);
		scope.join(continuing);
		return TTry(typedTry, typedCatches, span);
	}

	public function typeIf(predicate:AstExpression, thenBranch:Array<AstStatement>, elseBranch:Array<AstStatement>,
			span:SourceSpan, scope:Scope,
			result:Null<CompilerType>):TypedStatement {
		var typedCondition = ConversionResolver.plainValue(typeExpression(predicate, scope, null, false), coerce);
		if (!TypeRelations.equals(typedCondition.type, TBool))
			fail("E1004", "If condition must be Bool", span);
		var thenScope = FlowAnalysis.narrowedScope(scope, typedCondition, true, session.isPureCall),
			elseScope = FlowAnalysis.narrowedScope(scope, typedCondition, false, session.isPureCall),
			typedThen = typeStatements(thenBranch, thenScope, result),
			typedElse = typeStatements(elseBranch, elseScope, result),
			continuing:Array<Scope> = [];
		if (!ControlFlow.alwaysExits(typedThen, exhaustiveEnum))
			continuing.push(thenScope);
		if (ControlFlow.elseCanRun(typedCondition)
			&& (elseBranch.length == 0 || !ControlFlow.alwaysExits(typedElse, exhaustiveEnum)))
			continuing.push(elseScope);
		scope.join(continuing);
		if (elseBranch.length == 0 && ControlFlow.elseCanRun(typedCondition)
			&& ControlFlow.alwaysExits(typedThen, exhaustiveEnum))
			FlowAnalysis.refineAfterGuard(scope, typedCondition, session.isPureCall);
		return TIf(typedCondition, typedThen, typedElse, span);
	}

	public function typeWhile(predicate:AstExpression, body:Array<AstStatement>, span:SourceSpan, scope:Scope,
			result:Null<CompilerType>):TypedStatement {
		LoopFlow.enter(session, scope, body.concat([Expression(predicate, span)]));
		var typedCondition = ConversionResolver.plainValue(typeExpression(predicate, scope, null, false), coerce);
		if (!TypeRelations.equals(typedCondition.type, TBool))
			fail("E1004", "While condition must be Bool", span);
		var context = session.currentContext;
		context.loopDepth++;
		// The condition is evaluated right before every iteration, so what it proves holds where the body starts.
		var typedBody = typeStatements(body,
			FlowAnalysis.narrowedScope(scope, typedCondition, true, session.isPureCall), result);
		context.loopDepth--;
		// The loop ends when the condition is false, unless a break leaves it first.
		if (!AstScan.breaksOut(body))
			FlowAnalysis.refineAfterGuard(scope, typedCondition, session.isPureCall);
		return TWhile(typedCondition, typedBody, span);
	}

	public function typeDoWhile(body:Array<AstStatement>, predicate:AstExpression, span:SourceSpan, scope:Scope,
			result:Null<CompilerType>):TypedStatement {
		LoopFlow.enter(session, scope, body.concat([Expression(predicate, span)]));
		var bodyScope = new Scope(scope), context = session.currentContext;
		context.loopDepth++;
		var typedBody = typeStatements(body, bodyScope, result);
		context.loopDepth--;
		var typedCondition = ConversionResolver.plainValue(typeExpression(predicate, bodyScope, null, false), coerce);
		if (!TypeRelations.equals(typedCondition.type, TBool))
			fail("E1004", "Do-while condition must be Bool", span);
		// The body runs at least once, so what it assigns and narrows holds afterwards, unless a break or continue can skip the
		// rest of it.
		if (!AstScan.breaksOut(body) && !AstScan.continuesOut(body))
			scope.join([bodyScope]);
		if (!AstScan.breaksOut(body))
			FlowAnalysis.refineAfterGuard(scope, typedCondition, session.isPureCall);
		return TDoWhile(typedBody, typedCondition, span);
	}

	public function typeForIn(name:String, valueName:Null<String>, iterable:AstExpression, body:Array<AstStatement>,
			span:SourceSpan, scope:Scope,
			result:Null<CompilerType>):TypedStatement {
		var typedIterable = unwrapNullable(typeExpression(iterable, scope, null, false));
		if (IterationProtocol.structuralIterator(typedIterable.type))
			IterationProtocol.invalidateEffects(session, scope);
		var forwardedArray = AbstractForwarding.arrayStorage(session, typedIterable.type, "iterator");
		if (forwardedArray != null)
			typedIterable = session.representation.boundaryCast(typedIterable, forwardedArray);
		// Haxe iterates any class instance or structure through its `iterator()` method.
		if (valueName == null
			&& IterationProtocol.structuralIterator(typedIterable.type)
			&& IterationProtocol.method(session.declarations, typedIterable.type, "iterator") != null)
			typedIterable = unwrapNullable(IterationProtocol.call(session, typedIterable, "iterator"));
		// `for (index => element in array)` is a loop over the indices that binds each element.
		if (valueName != null)
			switch typedIterable.type {
				case TArray(_):
					var array = "__haxeon_array" + span.start,
						loopBody:Array<AstStatement> = [
							VarDeclaration(valueName, null, Index(Variable(array, span), Variable(name, span), span),
								span)
						];
					for (statement in body)
						loopBody.push(statement);
					return typeIf(BoolLiteral(true, span), [
						VarDeclaration(array, null, iterable, span),
						ForIn(name, null, Range(IntegerLiteral(0, span), Member(Variable(array, span), "length", span),
							span), loopBody, span)
					], [], span, scope, result);
				default:
			}
		var originalIterable = typedIterable;
		LoopFlow.enter(session, scope, body, [name, valueName]);
		var element:CompilerType = switch typedIterable.type {
			case TArray(element): element;
			case TIterator(element): element;
			case TRange: TInt;
			case TMap(key, value):
				var mapName = session.mapName(key, value);
				if (mapName == null)
					fail("E1016", "This map key/value type has no compiler-owned runtime ABI", span);
				if (valueName == null) {
					typedIterable = new TypedExpression(TCollectionCall(typedIterable, "values", []), TArray(value),
						span);
					value;
				} else key;
			default:
				var item = valueName == null ? IterationProtocol.element(session.declarations, typedIterable.type,
					false) : null;
				if (item == null)
					fail("E1014", "For-in requires an iterable or an iterator with hasNext():Bool and next()", span);
				item;
		};
		var loopScope = new Scope(scope);
		loopScope.define(name, element, span);
		bindCell(name, span, loopScope, element);
		// Keys come from a snapshot, so an entry the body removes may still be visited later.
		if (valueName == null && !AstScan.mayRemoveMapEntries(body, name)) {
			var map = mapKeyIteratorSource(originalIterable);
			if (map == null)
				map = FlowAnalysis.mapKeySource(originalIterable, scope);
			if (map != null) {
				var key = new TypedExpression(TLocal(loopScope.requireId(name)), element, span),
					entryPath = FlowAnalysis.mapEntryPath(map, key);
				if (entryPath != null)
					switch map.type {
						case TMap(_, value):
							loopScope.refineExpression(entryPath, value,
								FlowAnalysis.entryFactsSurviveCalls(scope, map));
						default:
					}
			}
		}
		if (valueName != null)
			switch originalIterable.type {
				case TMap(_, value):
					loopScope.define(valueName, value, span);
					bindCell(valueName, span, loopScope, value);
				default:
					fail("E1014", "Key/value for-in requires a Map", span);
			}
		var context = session.currentContext;
		context.loopDepth++;
		var typedBody = typeStatements(body, loopScope, result);
		context.loopDepth--;
		var valueId:Null<String> = valueName == null ? null : loopScope.requireId(valueName);
		if (IterationProtocol.structuralIterator(typedIterable.type)) {
			var held = "$for-iterator:" + span.start;
			var receiver = new TypedExpression(TLocal(held), typedIterable.type, span);
			var hasNext = IterationProtocol.call(session, receiver, "hasNext");
			var next = IterationProtocol.call(session, receiver, "next");
			return TIf(new TypedExpression(TBoolLiteral(true), TBool, span), [
				TVar(held, typedIterable, span),
				TWhile(hasNext, [TVar(loopScope.requireId(name), next, span)].concat(typedBody), span)
			], [], span);
		}
		return TForIn(loopScope.requireId(name), valueId, valueName == null ? typedIterable : originalIterable,
			typedBody, span);
	}

	public function typeSwitch(expression:AstExpression, cases:Array<AstSwitchCase>, defaultBranch:Array<AstStatement>,
			hasDefault:Bool, span:SourceSpan,
			scope:Scope, result:Null<CompilerType>):TypedStatement {
		var typedExpression = typeExpression(expression, scope, null, false),
			constantType = switchRules.constantType(typedExpression.type);
		if (constantType == null && !isArraySwitchable(typedExpression.type)
			&& !switchRules.isEnum(typedExpression.type))
			fail("E1019", "Switch requires an Int, String, array, or enum value", typedExpression.span);
		var typedCases:Array<TypedSwitchCase> = [],
			caseScopes:Array<Scope> = [],
			seenCases:Map<String, Bool> = [];
		for (switchCase in cases) {
			var caseScope = new Scope(scope),
				classified = switchRules.casePattern(switchCase.value, typedExpression.type, caseScope),
				subjectBinding = classified.subjectBinding,
				isCatchAll = classified.isCatchAll,
				arrayPattern = classified.arrayPattern,
				pattern = classified.enumPattern,
				typedValue = isCatchAll
					|| arrayPattern != null ? typedExpression : pattern == null ? typeCaseConstant(classified.value,
					typedExpression.type, constantType,
					scope) : pattern.value;
			var parsedGuard = switchCase.guard,
				typedGuard = parsedGuard == null ? null : coerce(typeExpression(parsedGuard, caseScope, null, false),
					TBool, "switch guard", "E1003");
			if (typedGuard != null)
				caseScope = FlowAnalysis.narrowedScope(caseScope, typedGuard, true, session.isPureCall);
			var typedBody = typeStatements(switchCase.statements, caseScope, result),
				constructorIndex = pattern == null ? -1 : pattern.index,
				enumName:Null<String> = pattern == null ? null : pattern.enumName,
				bindings:Array<TypedSwitchBinding> = pattern == null ? [] : pattern.bindings,
				predicates:Array<TypedSwitchPredicate> = pattern == null ? [] : pattern.predicates;
			caseScopes.push(caseScope);
			if (pattern == null) {
				var literal = switchRules.enumLiteral(typedValue);
				if (literal != null) {
					enumName = literal.name;
					constructorIndex = literal.index;
				}
			}
			var caseKey = arrayPattern == null ? switchRules.caseKey(typedValue,
				predicates) : switchRules.arrayPatternKey(arrayPattern);
			if (isCatchAll)
				seenCases.set("$catchall", true);
			if (caseKey != null && typedGuard == null) {
				if (seenCases.exists(caseKey))
					fail("E1020", "Duplicate switch case", switchCase.span);
				seenCases.set(caseKey, true);
			}
			typedCases.push({
				value: typedValue,
				subjectBinding: subjectBinding,
				arrayPattern: arrayPattern,
				isCatchAll: isCatchAll,
				guard: typedGuard,
				statements: typedBody,
				enumName: enumName,
				constructorIndex: constructorIndex,
				bindings: bindings,
				predicates: predicates,
				span: switchCase.span
			});
		}
		if (switchRules.isEnum(typedExpression.type) && !hasDefault && !seenCases.exists("$catchall")) {
			var enumName = Std.string(switchRules.enumName(typedExpression.type));
			var missing:Array<String> = [],
				coverageCases:Array<TypedSwitchCoverageCase> = [for (switchCase in typedCases)
					{
						constructorIndex:switchCase.constructorIndex,
							subjectBinding:switchCase.subjectBinding,
							isCatchAll:switchCase.isCatchAll,
							guard:switchCase.guard,
							predicates:switchCase.predicates
					}];
			if (session.enumDecls.exists(enumName)) {
				var enumDecl = session.enumDecls.get(enumName);
				for (index in 0...enumDecl.cases.length)
					if (!seenCases.exists('enum:$enumName:$index')
						&& !switchRules.enumCaseCovered(typedExpression.type, index, coverageCases))
						missing.push(enumDecl.cases[index].name);
			}
			if (switchRules.isNullableEnum(typedExpression.type) && !seenCases.exists("null"))
				missing.push("null");
			if (missing.length > 0)
				fail("E1021", 'Enum switch is missing cases: ${missing.join(", ")}', span);
		}
		// A switch over a closed enum abstract covers every declared value, as one over an enum covers every constructor.
		// Its implicit default throws, so a value outside the declared set fails at the switch rather than skipping it.
		var unmatchedEnumAbstract:Null<String> = null;
		if (!hasDefault && !seenCases.exists("$catchall")) {
			var values = switchRules.closedEnumAbstractValues(typedExpression.type);
			if (values != null) {
				var missing = [for (value in values) if (!seenCases.exists(value.key)) value.name];
				if (missing.length > 0)
					fail("E1021", 'Enum abstract switch is missing values: ${missing.join(", ")}', span);
				unmatchedEnumAbstract =
					'Unmatched ${compiler.semantic.SemanticSignature.display(typedExpression.type)} value';
			}
		}
		var defaultScope = new Scope(scope),
			typedDefault = typeStatements(defaultBranch, defaultScope, result),
			continuing:Array<Scope> = [];
		if (unmatchedEnumAbstract != null) {
			typedDefault = [TThrow(new TypedExpression(TStringLiteral(unmatchedEnumAbstract), TString, span), span)];
			hasDefault = true;
		}
		for (i in 0...typedCases.length)
			if (!ControlFlow.alwaysExits(typedCases[i].statements, exhaustiveEnum))
				continuing.push(caseScopes[i]);
		if (hasDefault) {
			if (!ControlFlow.alwaysExits(typedDefault, exhaustiveEnum))
				continuing.push(defaultScope);
		} else if (!exhaustiveEnum(typedExpression.type, typedCases))
			continuing.push(scope);
		scope.join(continuing);
		return TSwitch(typedExpression, typedCases, typedDefault, hasDefault, span);
	}

	/** A constant case, typed as the subject's value: `case null` alone is typed as the (nullable) subject. */
	function typeCaseConstant(value:AstExpression, subjectType:CompilerType, constantType:Null<CompilerType>,
			scope:Scope):TypedExpression {
		var type = constantType == null
			|| compiler.syntax.AstPredicates.isNullExpression(value) ? subjectType : constantType;
		return coerce(typeExpression(value, scope, type, false), type, "switch case", "E1019");
	}

	static function isArraySwitchable(type:CompilerType):Bool
		return switch type {
			case TArray(_): true;
			default: false;
		};

	static function rejectFinalAnonymousFieldMutation(type:CompilerType, name:String, span:SourceSpan):Void
		switch type {
			case TAnonymous(_, fields):
				for (field in fields)
					if (field.name == name && field.isFinal)
						fail("E1024", 'Final anonymous field "$name" cannot be assigned', span);
			default:
		}

	@:noReturn
	static function fail(code:String, message:String, span:SourceSpan):Void
		throw new CompileError(new Diagnostic(code, message, span));
}
