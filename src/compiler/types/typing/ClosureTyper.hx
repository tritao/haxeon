package compiler.types.typing;

import compiler.Diagnostic;
import compiler.Diagnostic.CompileError;
import compiler.Source.SourceSpan;
import compiler.semantic.SemanticProgram.SemanticMethodInfo;
import compiler.syntax.Ast.AstArgument;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstStatement;
import compiler.syntax.Ast.AstType;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;
import compiler.types.TypeRelations;
import compiler.types.TypedAst.CellStorageKind;
import compiler.types.TypedAst.TypedCapture;
import compiler.types.TypedAst.TypedCaptureSource;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedExpressionKind;
import compiler.types.TypedAst.TypedStatement;
import compiler.types.analysis.CaptureAnalysis;
import compiler.types.analysis.ControlFlow;
import compiler.types.analysis.LexicalStorageAnalysis;
import compiler.types.analysis.Scope;

typedef ClosureExpressionCallback = (AstExpression, Scope, Null<CompilerType>, Bool) -> TypedExpression;
typedef ClosureLowerTypeCallback = AstType->CompilerType;
typedef ClosureMethodLookupCallback = String->Null<SemanticMethodInfo>;
typedef ClosureFieldLookupCallback = (CompilerType, String) -> Null<CompilerType>;
typedef ClosureBoundCellCallback = (String, Scope) -> Null<String>;
typedef ClosureEnterBodyCallback = (String, Null<Map<String, CompilerType>>, Null<String>) -> TypingContext;
typedef ClosureLeaveBodyCallback = TypingContext->Void;
typedef ClosureBindCellCallback = (String, SourceSpan, Scope, CompilerType) -> Void;
typedef ClosureTypeStatementsCallback = (Array<AstStatement>, Scope, Null<CompilerType>) -> Array<TypedStatement>;
typedef ClosureAlwaysReturnsCallback = Array<TypedStatement>->Bool;

/** Types lambda bodies and coordinates their capture and closure-conversion records. */
class ClosureTyper {
	final session:TypingSession;
	final typeExpression:ClosureExpressionCallback;
	final lowerType:ClosureLowerTypeCallback;
	final lexicalMethod:ClosureMethodLookupCallback;
	final findFieldType:ClosureFieldLookupCallback;
	final boundCell:ClosureBoundCellCallback;
	final enterBody:ClosureEnterBodyCallback;
	final leaveBody:ClosureLeaveBodyCallback;
	final bindCell:ClosureBindCellCallback;
	final typeStatements:ClosureTypeStatementsCallback;
	final alwaysReturns:ClosureAlwaysReturnsCallback;

	public function new(session:TypingSession, typeExpression:ClosureExpressionCallback, lowerType:ClosureLowerTypeCallback,
			lexicalMethod:ClosureMethodLookupCallback, findFieldType:ClosureFieldLookupCallback, boundCell:ClosureBoundCellCallback,
			enterBody:ClosureEnterBodyCallback, leaveBody:ClosureLeaveBodyCallback, bindCell:ClosureBindCellCallback,
			typeStatements:ClosureTypeStatementsCallback, alwaysReturns:ClosureAlwaysReturnsCallback) {
		this.session = session;
		this.typeExpression = typeExpression;
		this.lowerType = lowerType;
		this.lexicalMethod = lexicalMethod;
		this.findFieldType = findFieldType;
		this.boundCell = boundCell;
		this.enterBody = enterBody;
		this.leaveBody = leaveBody;
		this.bindCell = bindCell;
		this.typeStatements = typeStatements;
		this.alwaysReturns = alwaysReturns;
	}

	public function typeLambda(arguments:Array<AstArgument>, body:Array<AstStatement>, span:SourceSpan, scope:Scope, expectedType:Null<CompilerType>,
			inferDynamicLambdaResult:Bool, outerContext:TypingContext):TypedExpression {
		var lambdaKey = '${outerContext.name}:${span.file.path}:${span.start}';
		if (session.lambdaCache.exists(lambdaKey))
			return session.lambdaCache.get(lambdaKey);
		var expectedFunction = expectedFunctionType(expectedType),
			inferContextualResult = expectedFunction != null && expectedFunction.result == TDynamic && inferDynamicLambdaResult;
		if (expectedFunction != null && expectedFunction.arguments.length != arguments.length)
			fail("E1008", 'Lambda expects ${expectedFunction.arguments.length} arguments, got ${arguments.length}', span);
		var lambdaArguments:Array<{name:String, type:CompilerType}> = [],
			lambdaScope = new Scope(),
			declared:Map<String, Bool> = [];
		for (i in 0...arguments.length) {
			var argument = arguments[i],
				localName = argument.name == "_" ? '$' + 'discard:$i' : argument.name;
			var argumentType = argument.type == InferredType ? (expectedFunction == null ? null : expectedFunction.arguments[i]) : lowerType(argument.type);
			if (argumentType != null
				&& argument.type != InferredType
				&& argument.optional == true
				&& compiler.syntax.AstPredicates.isNullExpression(argument.defaultValue))
				argumentType = switch argumentType {
					case TNullable(_): argumentType;
					default: TNullable(argumentType);
				};
			if (argumentType == null)
				fail("E1003", 'Cannot infer lambda parameter "${argument.name}" without a function context', argument.span);
			if (expectedFunction != null && !TypeRelations.equals(argumentType, expectedFunction.arguments[i]))
				fail("E1003", "Lambda argument type does not match its context", argument.span);
			lambdaScope.define(localName, argumentType, argument.span);
			lambdaArguments.push({name: lambdaScope.requireId(localName), type: argumentType});
			if (argument.name != "_")
				declared.set(argument.name, true);
		}
		CaptureAnalysis.collectDeclaredLocals(body, declared);
		var freeVariables:Map<String, Bool> = [];
		CaptureAnalysis.collectVariables(body, freeVariables);
		var lambdaAssignments:Map<String, Bool> = [];
		CaptureAnalysis.collectAssignedLocals(body, lambdaAssignments);
		// An unqualified instance method in a lambda is resolved through the lexical receiver even without a `this` reference in the syntax.
		if (scope.resolve("this") != null)
			for (name in freeVariables.keys())
				if (scope.resolve(name) == null) {
					var method = lexicalMethod(name),
						receiverType = scope.resolve("this");
					if (method != null && !method.isStatic || receiverType != null && findFieldType(receiverType, name) != null)
						freeVariables.set("this", true);
				}
		var captures:Array<TypedCapture> = [],
			captureCells:Map<String, String> = [],
			captureTypes:Map<String, CompilerType> = [];
		// Map iteration order differs between hosts; sort so closure layouts are deterministic.
		var freeNames = [for (name in freeVariables.keys()) name];
		freeNames.sort(Reflect.compare);
		for (name in freeNames)
			if (!declared.exists(name)) {
				var capturedType = scope.resolve(name);
				if (capturedType != null) {
					var captureType:CompilerType = capturedType;
					var cellClass:Null<String> = null;
					if (boundCell(name, scope) != null)
						cellClass = boundCell(name, scope);
					if (cellClass == null && scope.isCellCapture(name))
						cellClass = scope.requireCellClass(name);
					if (cellClass == null && (outerContext.assigned.exists(name) || lambdaAssignments.exists(name))) {
						var newCellClass = '$' + 'cell:' + outerContext.name + ':' + name;
						var bindingId = scope.requireId(name);
						cellClass = outerContext.storage.requestBinding(bindingId, newCellClass, MutableCapture, captureType);
					}
					var bindingId = scope.requireId(name),
						declaredCaptureType = scope.resolveDeclared(name),
						captureSource:TypedCaptureSource = if (scope.isCellCapture(name)) CaptureCellEnvironmentField(name,
							scope.requireCellClass(name)) else if (scope.isCapture(name)) CaptureEnvironmentField(name) else if (cellClass != null)
							CaptureCellLocal(bindingId, cellClass) else if (scope.isReceiver(name)) CaptureReceiver else CaptureLocal(bindingId);
					lambdaScope.defineCapture(name, captureType, span, cellClass != null, cellClass, bindingId,
						declaredCaptureType == null ? captureType : declaredCaptureType, scope.localFunctionParameters(name));
					if (cellClass != null)
						captureCells.set(name, cellClass);
					captureTypes.set(name, captureType);
					captures.push({
						field: name,
						bindingId: bindingId,
						type: captureType,
						storageType: declaredCaptureType == null ? captureType : declaredCaptureType,
						source: captureSource
					});
				}
			}
		var typedBodyScope = new Scope();
		for (i in 0...lambdaArguments.length) {
			var localName = arguments[i].name == "_" ? '$' + 'discard:$i' : arguments[i].name;
			typedBodyScope.define(localName, lambdaArguments[i].type, arguments[i].span);
			lambdaArguments[i] = {name: typedBodyScope.requireId(localName), type: lambdaArguments[i].type};
		}
		for (capture in captures)
			typedBodyScope.defineCapture(capture.field, capture.type, span, captureCells.exists(capture.field), captureCells.get(capture.field),
				capture.bindingId, capture.storageType, scope.localFunctionParameters(capture.field));
		var lambdaName = '$' + 'lambda:${outerContext.name}:${span.start}',
			lambdaContext = enterBody(lambdaName, outerContext.typeSubstitutions, null),
			context = session.currentContext;
		context.scope = typedBodyScope;
		context.receiver = typedBodyScope.resolve("this");
		context.expectedReturnType = expectedFunction == null || inferContextualResult ? TVoid : expectedFunction.result;
		context.contextualVoidLambda = expectedFunction != null && expectedFunction.result == TVoid;
		CaptureAnalysis.collectAssignedLocals(body, context.assigned);
		var lambdaStorage = LexicalStorageAnalysis.analyze(body, arguments);
		for (binding in lambdaStorage.mutableCaptures.keys())
			context.storage.request(binding, '$' + 'cell:' + lambdaName + ':' + binding, MutableCapture);
		for (binding in lambdaStorage.exceptionCells.keys())
			context.storage.request(binding, "$cell:" + lambdaName + ":" + binding, ExceptionEdge);
		for (i in 0...arguments.length)
			bindCell(arguments[i].name == "_" ? "$discard:" + i : arguments[i].name, arguments[i].span, typedBodyScope, lambdaArguments[i].type);
		var typedBody = typeStatements(body, typedBodyScope, expectedFunction == null
			|| inferContextualResult ? null : expectedFunction.result),
			inferredResult:CompilerType;
		if (expectedFunction != null && !inferContextualResult)
			inferredResult = expectedFunction.result;
		else {
			var contextualResult = context.inferredResult;
			inferredResult = contextualResult == null ? CompilerType.TVoid : contextualResult;
		}
		context.expectedReturnType = inferredResult;
		var lambdaCells = copyMap(context.storage.cells),
			lambdaCellTypes = copyMap(context.storage.types),
			lambdaCellKinds = copyMap(context.storage.kinds);
		leaveBody(lambdaContext);
		if (inferredResult != TVoid && !alwaysReturns(typedBody))
			fail("E1006", 'Function $lambdaName does not return on every path', span);
		var environment:Null<String> = null;
		if (captures.length > 0)
			environment = '$' + 'lambda-env:${session.currentContext.name}:${span.start}';
		if (environment != null)
			session.closureConversion.addEnvironment(environment, captures);
		session.closureConversion.addFunction({
			name: lambdaName,
			genericOrigin: outerContext.name,
			owner: environment,
			isStatic: environment == null,
			isConstructor: false,
			arguments: lambdaArguments,
			result: inferredResult,
			statements: typedBody,
			cells: lambdaCells,
			cellCaptures: copyMap(captureCells),
			span: span
		});
		for (name in lambdaCells.keys())
			if (lambdaCellTypes.exists(name) && lambdaCellKinds.exists(name))
				session.closureConversion.addCell(requiredMapValue(lambdaCells, name), requiredMapValue(lambdaCellTypes, name),
					requiredMapValue(lambdaCellKinds, name));
		var lambdaResult = new TypedExpression(TLambda(lambdaName, environment, captures),
			TFunction([for (argument in lambdaArguments) argument.type], inferredResult), span);
		session.lambdaCache.set(lambdaKey, lambdaResult);
		return lambdaResult;
	}

	static function expectedFunctionType(type:Null<CompilerType>):Null<{arguments:Array<CompilerType>, result:CompilerType}> {
		if (type == null)
			return null;
		return switch type {
			case TFunction(arguments, result): {arguments: arguments, result: result};
			case TNullable(inner): expectedFunctionType(inner);
			default: null;
		};
	}

	static function copyMap<T>(source:Map<String, T>):Map<String, T> {
		var result:Map<String, T> = [];
		for (key => value in source)
			result.set(key, value);
		return result;
	}

	static function requiredMapValue<T>(source:Map<String, T>, name:String):T {
		if (!source.exists(name))
			throw 'Missing map entry "$name"';
		return source.get(name);
	}

	static function fail(code:String, message:String, span:SourceSpan):Void
		throw new CompileError(new Diagnostic(code, message, span));
}
