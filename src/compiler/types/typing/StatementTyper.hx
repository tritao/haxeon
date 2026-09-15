package compiler.types.typing;

import compiler.Diagnostic;
import compiler.Diagnostic.CompileError;
import compiler.Source.SourceSpan;
import compiler.runtime.PlatformAbi;
import compiler.runtime.RuntimeType;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstCatch;
import compiler.syntax.Ast.AstStatement;
import compiler.syntax.Ast.AstSwitchCase;
import compiler.syntax.Ast.AstType;
import compiler.types.Type.CompilerType;
import compiler.types.analysis.ControlFlow;
import compiler.types.analysis.FlowAnalysis;
import compiler.types.analysis.LexicalStorageAnalysis;
import compiler.types.TypeRelations;
import compiler.types.analysis.Scope;
import compiler.types.TypedAst.TypedCatch;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedStatement;
import compiler.types.TypedAst.TypedSwitchBinding;
import compiler.types.TypedAst.TypedSwitchCase;
import compiler.types.TypedAst.TypedSwitchPredicate;

typedef StatementExpressionCallback = (AstExpression, Scope, Null<CompilerType>, Bool) -> TypedExpression;
typedef StatementCoerceCallback = (TypedExpression, CompilerType, String, String) -> TypedExpression;
typedef ExpectedInitializerCallback = (String, AstExpression, Array<AstStatement>, Int) -> Null<CompilerType>;
typedef BindCellCallback = (String, SourceSpan, Scope, CompilerType) -> Void;
typedef TypeStatementsCallback = (Array<AstStatement>, Scope, Null<CompilerType>) -> Array<TypedStatement>;
typedef ExhaustiveEnumCallback = (CompilerType, Array<TypedSwitchCase>) -> Bool;
typedef LowerTypeCallback = AstType->CompilerType;
typedef NullableUnwrapper = TypedExpression->TypedExpression;
typedef MapKeyIteratorSource = TypedExpression->Null<TypedExpression>;

typedef SwitchPattern = {
	value:TypedExpression,
	enumName:String,
	index:Int,
	bindings:Array<TypedSwitchBinding>,
	predicates:Array<TypedSwitchPredicate>
};

typedef SwitchTypingRules = {
	subjectBinding:(AstExpression, CompilerType, Scope) -> Null<String>,
	catchAll:AstExpression->Bool,
	enumPattern:(AstExpression, CompilerType, Scope) -> Null<SwitchPattern>,
	caseKey:(TypedExpression, Array<TypedSwitchPredicate>) -> Null<String>,
	enumLiteral:TypedExpression->Null<{name:String, index:Int}>,
	isEnum:CompilerType->Bool,
	isNullableEnum:CompilerType->Bool,
	enumName:CompilerType->Null<String>
};

typedef StaticFieldInfo = {owner:String, type:CompilerType};

typedef AssignmentTypingRules = {
	findStaticField:(String, String) -> Null<StaticFieldInfo>,
	requireStaticField:(String, String, SourceSpan) -> StaticFieldInfo,
	rejectInlineFieldMutation:(String, String, SourceSpan) -> Void,
	findFieldType:(CompilerType, String) -> Null<CompilerType>,
	instancePropertyAccessor:(CompilerType, String, Bool) -> Null<String>,
	fieldType:(CompilerType, String, SourceSpan) -> CompilerType,
	fieldRepresentationType:(CompilerType, String, SourceSpan) -> CompilerType,
	nativeField:(TypedExpression, String, SourceSpan) -> Null<{
		pointer:TypedExpression,
		type:CompilerType,
		size:Int,
		signed:Bool,
		arrayLength:Null<Int>,
		addressOnly:Bool
	}>,
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

	public function new(session:TypingSession, typeExpression:StatementExpressionCallback, coerce:StatementCoerceCallback,
			expectedInitializerType:ExpectedInitializerCallback, bindCell:BindCellCallback, typeStatements:TypeStatementsCallback,
			exhaustiveEnum:ExhaustiveEnumCallback, lowerType:LowerTypeCallback, unwrapNullable:NullableUnwrapper, mapKeyIteratorSource:MapKeyIteratorSource,
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

	/** Returns null for statements handled by the compound-statement dispatcher. */
	public function typeSimpleStatement(statement:AstStatement, scope:Scope, result:Null<CompilerType>, statements:Array<AstStatement>,
			statementIndex:Int):Null<Array<TypedStatement>> {
		var context = session.currentContext;
		return switch statement {
			case ErrorStatement(_): [];
			case UninitializedDeclaration(name, declared, span):
				var declaredType = session.declarations.resolve(declared, null, context.typeSubstitutions),
					declarationKey = LexicalStorageAnalysis.key(name, span);
				if (context.storage.hasCandidate(declarationKey) && context.storage.candidateKind(declarationKey) == MutableCapture)
					fail("E1023", 'Captured local "$name" must be initialized at its declaration', span);
				scope.define(name, declaredType, span, false);
				bindCell(name, span, scope, declaredType);
				[TDeclare(scope.requireId(name), declaredType, span)];
			case VarDeclaration(name, declared, initializer, span):
				var declaredType:Null<CompilerType> = declared == null ? expectedInitializerType(name, initializer, statements,
					statementIndex + 1) : session.declarations.resolve(declared, null, context.typeSubstitutions);
				var predeclared = false;
				if (declaredType != null)
					switch initializer {
						case Lambda(_, _, _):
							scope.define(name, declaredType, span);
							predeclared = true;
						default:
					}
				var value = typeExpression(initializer, scope, declaredType, false);
				if (declaredType != null)
					value = coerce(value, declaredType, 'local "$name"', "E1002");
				else if (TypeRelations.equals(value.type, TNull))
					fail("E1002", 'Null requires an explicit nullable type for local "$name"', span);
				if (!predeclared)
					scope.define(name, value.type, span);
				bindCell(name, span, scope, value.type);
				[TVar(scope.requireId(name), value, span)];
			case Return(expression, span):
				var expected = result == null ? context.inferredResult : result;
				var value = typeExpression(expression, scope, expected, false),
					output:Array<TypedStatement> = [];
				if (expected != null && expected == TVoid && context.contextualVoidLambda) {
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
				else if (expected != TVoid)
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
				if (!context.loopEarlyExits[context.loopDepth - 1])
					fail("E1017", "break in do-while is not supported by the current CFG backend", span);
				[TBreak(span)];
			case Continue(span):
				if (context.loopDepth == 0)
					fail("E1017", "continue is only valid inside a loop", span);
				if (!context.loopEarlyExits[context.loopDepth - 1])
					fail("E1017", "continue in do-while is not supported by the current CFG backend", span);
				[TContinue(span)];
			case Expression(expression, span):
				[TExpression(typeExpression(expression, scope, null, false), span)];
			default: null;
		};
	}

	public function typeIncrement(name:String, delta:Int, span:SourceSpan, scope:Scope):TypedStatement {
		var current = scope.resolve(name);
		if (current != null && !scope.isAssigned(name))
			fail("E1023", 'Local "$name" may be used before assignment', span);
		if (current == null) {
			var dot = name.indexOf("."),
				owner = dot < 0 ? session.currentContext.lexicalOwner : name.substring(0, dot),
				fieldName = dot < 0 ? name : name.substring(dot + 1, name.length),
				staticField:Null<StaticFieldInfo> = null;
			if (owner != null)
				staticField = assignmentRules.findStaticField(owner, fieldName);
			if (staticField == null || (!sameType(staticField.type, TInt) && !sameType(staticField.type, TFloat)))
				fail("E1018", 'Increment requires a numeric local or static field "$name"', span);
			assignmentRules.rejectInlineFieldMutation(staticField.owner, fieldName, span);
			var oldValue = new TypedExpression(TStaticField(staticField.owner, fieldName), staticField.type, span),
				one:TypedExpression = sameType(staticField.type,
					TInt) ? new TypedExpression(TIntLiteral(1), TInt, span) : new TypedExpression(TFloatLiteral(1.0), TFloat, span),
				updated = delta > 0 ? new TypedExpression(TAdd(oldValue, one), staticField.type,
					span) : new TypedExpression(TSub(oldValue, one), staticField.type, span);
			return TStaticFieldAssign(staticField.owner, fieldName, updated, span);
		}
		if (!sameType(current, TInt) && !sameType(current, TFloat))
			fail("E1018", 'Increment requires a numeric local "$name"', span);
		if (scope.isCapture(name)) {
			if (!scope.isCellCapture(name))
				fail("E1013", 'Captured variable "$name" requires mutable capture cells', span);
			return TCellCapturedIncrement(name, scope.requireCellClass(name), current, delta, span);
		}
		var cell = assignmentRules.boundCell(name, scope);
		return cell != null ? TCellIncrement(scope.requireId(name), cell, current, delta, span) : TIncrement(scope.requireId(name), delta, span);
	}

	public function typeAssignment(name:String, expression:AstExpression, span:SourceSpan, scope:Scope):TypedStatement {
		var dot = name.lastIndexOf(".");
		if (dot < 0) {
			var expected = scope.resolveDeclared(name);
			if (expected == null) {
				var thisType = scope.resolve("this"),
					instanceField = thisType == null ? null : assignmentRules.findFieldType(thisType, name);
				if (instanceField != null) {
					if (thisType == null)
						throw 'Missing "this" type for field "$name"';
					var value = coerce(typeExpression(expression, scope, instanceField, false), instanceField, 'field "$name"', "E1002");
					var receiver = typeExpression(Variable("this", span), scope, null, false),
						propertySetter = assignmentRules.instancePropertyAccessor(thisType, name, false);
					return propertySetter != null ? TExpression(new TypedExpression(TMethodCall(receiver, propertySetter, [value]), instanceField, span),
						span) : TFieldAssign(receiver, name,
							assignmentRules.abiBoundaryCast(value, assignmentRules.fieldRepresentationType(thisType, name, span)), span);
				}
				var owner = session.currentContext.lexicalOwner,
					staticField:Null<StaticFieldInfo> = null;
				if (owner != null)
					staticField = assignmentRules.findStaticField(owner, name);
				if (staticField == null)
					fail("E1005", 'Unknown variable "$name"', span);
				assignmentRules.rejectInlineFieldMutation(staticField.owner, name, span);
				var value = coerce(typeExpression(expression, scope, staticField.type, false), staticField.type, 'field "$name"', "E1002");
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
				statement = cell != null ? TCellAssign(scope.requireId(name), cell, value, span) : TAssign(scope.requireId(name), value, span);
			}
			scope.markAssigned(name);
			scope.invalidateExpressionsForLocal(name);
			scope.refine(name, assignmentFlowType(assignedValue.type, value.type));
			return statement;
		}

		var objectName = name.substring(0, dot),
			fieldName = name.substring(dot + 1, name.length),
			object = unwrapNullable(typeExpression(Variable(objectName, span), scope, null, false));
		return switch object.expression {
			case TClassRef(className):
				var staticField = assignmentRules.requireStaticField(className, fieldName, span);
				assignmentRules.rejectInlineFieldMutation(staticField.owner, fieldName, span);
				var value = coerce(typeExpression(expression, scope, staticField.type, false), staticField.type, 'field "$name"', "E1002");
				TStaticFieldAssign(staticField.owner, fieldName, value, span);
			default:
				var native = assignmentRules.nativeField(object, fieldName, span);
				if (native != null) {
					if (native.arrayLength != null || native.addressOnly)
						throw new CompileError(new Diagnostic("E1022", "Native fixed array fields cannot be assigned as a whole", span));
					var value = coerce(typeExpression(expression, scope, native.type, false), native.type, 'field "$name"', "E1002");
					TExpression(new TypedExpression(TCall("$rawptr.store",
						[native.pointer, value, new TypedExpression(TIntLiteral(native.size), TInt, span)]), TVoid, span),
						span);
				} else {
					var platformField = PlatformAbi.field(object.type, fieldName),
						expected = assignmentRules.fieldType(object.type, fieldName, span),
						value = coerce(typeExpression(expression, scope, expected, false), expected, 'field "$name"', "E1002"),
						setter:Null<String> = platformField == null ? null : platformField.set,
						statement = if (setter != null) TExpression(new TypedExpression(TCall(setter, [object, value]), TVoid, span), span) else {
							var propertySetter = assignmentRules.instancePropertyAccessor(object.type, fieldName, false);
							propertySetter != null ? TExpression(new TypedExpression(TMethodCall(object, propertySetter, [value]), expected, span), span) : {
								value = assignmentRules.abiBoundaryCast(value, assignmentRules.fieldRepresentationType(object.type, fieldName, span));
								TFieldAssign(object, fieldName, value, span);
							};
						};
					var objectPath = FlowAnalysis.accessPath(object);
					if (objectPath != null)
						scope.invalidateExpression(objectPath + "." + fieldName);
					statement;
				}
		};
	}

	public function typeIndexAssignment(array:AstExpression, offset:AstExpression, expression:AstExpression, span:SourceSpan, scope:Scope):TypedStatement {
		var typedArray = unwrapNullable(typeExpression(array, scope, null, false)),
			typedIndex = typeExpression(offset, scope, null, false);
		return switch typedArray.type {
			case TMap(key, mapValue):
				typedIndex = coerce(typedIndex, key, "map key", "E1002");
				var value = coerce(typeExpression(expression, scope, mapValue, false), mapValue, "map value", "E1002"),
					entryPath = FlowAnalysis.mapEntryPath(typedArray, typedIndex);
				if (entryPath != null)
					scope.refineExpression(entryPath, mapValue);
				TMapAssign(typedArray, typedIndex, value, span);
			default:
				if (typedIndex.type == TNever)
					typedIndex = coerce(typedIndex, TInt, "array index", "E1014");
				if (typedIndex.type != TInt)
					fail("E1014", "Array index must be Int", typedIndex.span);
				var element = assignmentRules.arrayElementType(typedArray.type, span),
					value = coerce(typeExpression(expression, scope, element, false), element, "array element", "E1002");
				TIndexAssign(typedArray, typedIndex, value, span);
		};
	}

	public function typeFieldAssignment(receiverExpression:AstExpression, fieldName:String, expression:AstExpression, span:SourceSpan,
			scope:Scope):TypedStatement {
		var object = unwrapNullable(typeExpression(receiverExpression, scope, null, false)),
			value = typeExpression(expression, scope, null, false);
		return switch object.expression {
			case TClassRef(className):
				var staticField = assignmentRules.requireStaticField(className, fieldName, span);
				assignmentRules.rejectInlineFieldMutation(staticField.owner, fieldName, span);
				value = coerce(value, staticField.type, 'field "$fieldName"', "E1002");
				TStaticFieldAssign(staticField.owner, fieldName, value, span);
			default:
				var native = assignmentRules.nativeField(object, fieldName, span);
				if (native != null) {
					if (native.arrayLength != null || native.addressOnly)
						throw new CompileError(new Diagnostic("E1022", "Native fixed array fields cannot be assigned as a whole", span));
					value = coerce(value, native.type, 'field "$fieldName"', "E1002");
					TExpression(new TypedExpression(TCall("$rawptr.store",
						[native.pointer, value, new TypedExpression(TIntLiteral(native.size), TInt, span)]), TVoid, span),
						span);
				} else {
					var platformField = PlatformAbi.field(object.type, fieldName),
						expected = assignmentRules.fieldType(object.type, fieldName, span);
					value = coerce(value, expected, 'field "$fieldName"', "E1002");
					var setter:Null<String> = platformField == null ? null : platformField.set;
					var statement = if (setter != null) TExpression(new TypedExpression(TCall(setter, [object, value]), TVoid, span), span) else {
						var propertySetter = assignmentRules.instancePropertyAccessor(object.type, fieldName, false);
						if (propertySetter != null)
							TExpression(new TypedExpression(TMethodCall(object, propertySetter, [value]), expected, span), span)
						else {
							value = assignmentRules.abiBoundaryCast(value, assignmentRules.fieldRepresentationType(object.type, fieldName, span));
							TFieldAssign(object, fieldName, value, span);
						}
					};
					var objectPath = FlowAnalysis.accessPath(object);
					if (objectPath != null)
						scope.invalidateExpression(objectPath + "." + fieldName);
					statement;
				}
		};
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

	public function typeTry(tryBranch:Array<AstStatement>, catches:Array<AstCatch>, span:SourceSpan, scope:Scope, result:Null<CompilerType>):TypedStatement {
		var typedCatches:Array<TypedCatch> = [],
			catchScopes:Array<Scope> = [],
			tryScope = new Scope(scope),
			typedTry = typeStatements(tryBranch, tryScope, result);
		for (i in 0...catches.length) {
			var catchClause = catches[i],
				loweredCatchType = lowerType(catchClause.type);
			switch loweredCatchType {
				case TDynamic:
					if (i != catches.length - 1)
						fail("E1022", "Dynamic catch must be the final catch clause", catchClause.span);
				case TInt, TFloat, TBool, TString:
				case TInstance(kind, _, arguments):
					if (Std.string(kind) != "class")
						fail("E1022", "Unsupported catch binding type", catchClause.span);
					if (arguments.length != 0)
						fail("E1022", "Unsupported generic catch binding type", catchClause.span);
				default:
					fail("E1022", "Unsupported catch binding type", catchClause.span);
			}
			var catchScope = new Scope(scope);
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
		scope.mergeAssignmentsFrom(continuing);
		scope.mergeRefinementsFrom(continuing);
		return TTry(typedTry, typedCatches, span);
	}

	public function typeIf(predicate:AstExpression, thenBranch:Array<AstStatement>, elseBranch:Array<AstStatement>, span:SourceSpan, scope:Scope,
			result:Null<CompilerType>):TypedStatement {
		var typedCondition = typeExpression(predicate, scope, null, false);
		if (!TypeRelations.equals(typedCondition.type, TBool))
			fail("E1004", "If condition must be Bool", span);
		var thenScope = FlowAnalysis.narrowedScope(scope, typedCondition, true),
			elseScope = FlowAnalysis.narrowedScope(scope, typedCondition, false),
			typedThen = typeStatements(thenBranch, thenScope, result),
			typedElse = typeStatements(elseBranch, elseScope, result),
			continuing:Array<Scope> = [];
		if (!ControlFlow.alwaysExits(typedThen, exhaustiveEnum))
			continuing.push(thenScope);
		if (elseBranch.length == 0)
			continuing.push(elseScope);
		else if (!ControlFlow.alwaysExits(typedElse, exhaustiveEnum))
			continuing.push(elseScope);
		scope.mergeAssignmentsFrom(continuing);
		scope.mergeRefinementsFrom(continuing);
		if (elseBranch.length == 0 && ControlFlow.alwaysExits(typedThen, exhaustiveEnum))
			FlowAnalysis.refineAfterGuard(scope, typedCondition);
		return TIf(typedCondition, typedThen, typedElse, span);
	}

	public function typeWhile(predicate:AstExpression, body:Array<AstStatement>, span:SourceSpan, scope:Scope, result:Null<CompilerType>):TypedStatement {
		var typedCondition = typeExpression(predicate, scope, null, false);
		if (!TypeRelations.equals(typedCondition.type, TBool))
			fail("E1004", "While condition must be Bool", span);
		var context = session.currentContext;
		context.loopEarlyExits[context.loopDepth] = true;
		context.loopDepth++;
		var typedBody = typeStatements(body, new Scope(scope), result);
		context.loopDepth--;
		return TWhile(typedCondition, typedBody, span);
	}

	public function typeDoWhile(body:Array<AstStatement>, predicate:AstExpression, span:SourceSpan, scope:Scope, result:Null<CompilerType>):TypedStatement {
		var bodyScope = new Scope(scope), context = session.currentContext;
		context.loopEarlyExits[context.loopDepth] = false;
		context.loopDepth++;
		var typedBody = typeStatements(body, bodyScope, result);
		context.loopDepth--;
		var typedCondition = typeExpression(predicate, bodyScope, null, false);
		if (!TypeRelations.equals(typedCondition.type, TBool))
			fail("E1004", "Do-while condition must be Bool", span);
		scope.mergeAssignmentsFrom([bodyScope]);
		return TDoWhile(typedBody, typedCondition, span);
	}

	public function typeForIn(name:String, valueName:Null<String>, iterable:AstExpression, body:Array<AstStatement>, span:SourceSpan, scope:Scope,
			result:Null<CompilerType>):TypedStatement {
		var typedIterable = unwrapNullable(typeExpression(iterable, scope, null, false)),
			originalIterable = typedIterable;
		var element:CompilerType = switch typedIterable.type {
			case TArray(element): element;
			case TIterator(element): element;
			case TRange: TInt;
			case TMap(key, value):
				var mapName = RuntimeType.mapName(key, value);
				if (mapName == null)
					fail("E1016", "This map key/value type has no compiler-owned runtime ABI", span);
				if (valueName == null) {
					typedIterable = new TypedExpression(TCollectionCall(typedIterable, "values", []), TArray(value), span);
					value;
				} else key;
			default:
				fail("E1014", "For-in iterable must be an Array, Iterator, or Map", span);
				TInt;
		};
		var loopScope = new Scope(scope);
		loopScope.define(name, element, span);
		bindCell(name, span, loopScope, element);
		if (valueName == null) {
			var map = mapKeyIteratorSource(originalIterable);
			if (map != null) {
				var key = new TypedExpression(TLocal(loopScope.requireId(name)), element, span),
					entryPath = FlowAnalysis.mapEntryPath(map, key);
				if (entryPath != null)
					switch map.type {
						case TMap(_, value):
							loopScope.refineExpression(entryPath, value);
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
		context.loopEarlyExits[context.loopDepth] = true;
		context.loopDepth++;
		var typedBody = typeStatements(body, loopScope, result);
		context.loopDepth--;
		var valueId:Null<String> = valueName == null ? null : loopScope.requireId(valueName);
		return TForIn(loopScope.requireId(name), valueId, valueName == null ? typedIterable : originalIterable, typedBody, span);
	}

	public function typeSwitch(expression:AstExpression, cases:Array<AstSwitchCase>, defaultBranch:Array<AstStatement>, hasDefault:Bool, span:SourceSpan,
			scope:Scope, result:Null<CompilerType>):TypedStatement {
		var typedExpression = typeExpression(expression, scope, null, false);
		if (!TypeRelations.equals(typedExpression.type, TInt)
			&& !TypeRelations.equals(typedExpression.type, TString)
			&& !switchRules.isEnum(typedExpression.type))
			fail("E1019", "Switch requires an Int, String, or enum value", typedExpression.span);
		var typedCases:Array<TypedSwitchCase> = [],
			caseScopes:Array<Scope> = [],
			seenCases:Map<String, Bool> = [];
		for (switchCase in cases) {
			var caseScope = new Scope(scope),
				subjectBinding = switchRules.subjectBinding(switchCase.value, typedExpression.type, caseScope),
				isCatchAll = switchRules.catchAll(switchCase.value),
				pattern = subjectBinding == null ? switchRules.enumPattern(switchCase.value, typedExpression.type, caseScope) : null,
				typedValue = isCatchAll
					|| subjectBinding != null ? typedExpression : pattern == null ? coerce(typeExpression(switchCase.value, scope, typedExpression.type,
						false), typedExpression.type, "switch case", "E1019") : pattern.value;
			var parsedGuard = switchCase.guard,
				typedGuard = parsedGuard == null ? null : coerce(typeExpression(parsedGuard, caseScope, null, false), TBool, "switch guard", "E1003");
			if (typedGuard != null)
				caseScope = FlowAnalysis.narrowedScope(caseScope, typedGuard, true);
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
			var caseKey = switchRules.caseKey(typedValue, predicates);
			if (isCatchAll || subjectBinding != null)
				seenCases.set("$catchall", true);
			if (caseKey != null && typedGuard == null) {
				if (seenCases.exists(caseKey))
					fail("E1020", "Duplicate switch case", switchCase.span);
				seenCases.set(caseKey, true);
			}
			typedCases.push({
				value: typedValue,
				subjectBinding: subjectBinding,
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
			var missing:Array<String> = [];
			if (session.enumDecls.exists(enumName)) {
				var enumDecl = session.enumDecls.get(enumName);
				for (index in 0...enumDecl.cases.length)
					if (!seenCases.exists('enum:$enumName:$index'))
						missing.push(enumDecl.cases[index].name);
			}
			if (switchRules.isNullableEnum(typedExpression.type) && !seenCases.exists("null"))
				missing.push("null");
			if (missing.length > 0)
				fail("E1021", 'Enum switch is missing cases: ${missing.join(", ")}', span);
		}
		var defaultScope = new Scope(scope),
			typedDefault = typeStatements(defaultBranch, defaultScope, result),
			continuing:Array<Scope> = [];
		for (i in 0...typedCases.length)
			if (!ControlFlow.alwaysExits(typedCases[i].statements, exhaustiveEnum))
				continuing.push(caseScopes[i]);
		if (hasDefault) {
			if (!ControlFlow.alwaysExits(typedDefault, exhaustiveEnum))
				continuing.push(defaultScope);
		} else if (!exhaustiveEnum(typedExpression.type, typedCases))
			continuing.push(scope);
		scope.mergeAssignmentsFrom(continuing);
		return TSwitch(typedExpression, typedCases, typedDefault, hasDefault, span);
	}

	static function fail(code:String, message:String, span:SourceSpan):Void
		throw new CompileError(new Diagnostic(code, message, span));
}
