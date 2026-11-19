package compiler.types.typing;

import compiler.core.InternalError;
import compiler.types.TypedAst.TypedFunctionRole;
import compiler.core.Diagnostic;
import compiler.core.Diagnostic.CompileError;
import compiler.core.Source.SourceSpan;
import compiler.syntax.Ast.AstArgument;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstStatement;
import compiler.syntax.Ast.AstType;
import compiler.types.FunctionTypes;
import compiler.types.Type.CompilerType;
import compiler.types.TypeRelations;
import compiler.types.TypedAst.CellStorageKind;
import compiler.types.TypedAst.TypedCapture;
import compiler.types.TypedAst.TypedCaptureSource;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedExpressionKind;
import compiler.types.analysis.AssignedDeclarations;
import compiler.types.analysis.BindingWalker;
import compiler.types.analysis.FreeVariables;
import compiler.types.analysis.ControlFlow;
import compiler.types.analysis.BodyResolution;
import compiler.types.analysis.Scope.LocalBinding;
import compiler.types.analysis.StorageRequirements;
import compiler.types.analysis.Scope;

/** Types lambda bodies and coordinates their capture and closure-conversion records. */
class ClosureTyper {
	final session:TypingSession;
	final bodyTyper:BodyTyping;

	public function new(session:TypingSession, bodyTyper:BodyTyping) {
		this.session = session;
		this.bodyTyper = bodyTyper;
	}

	/**
	 * The names a lambda reads, calls or writes without declaring them (`free`, by the local before any dot), those it assigns
	 * directly (`freeAssigned`), and the declarations of its own it writes (`assigned`): from the function's resolution when it
	 * knows the lambda at `span`, else by walking it. `body` is `sourceBody` with the default-argument prologue, which writes
	 * only the lambda's parameters. With `CompileOptions.checkResolution` the two answers must agree.
	 */
	static function requiredCell(cell:Null<String>, name:String):String {
		if (cell == null)
			throw new InternalError('Missing capture cell for "$name"');
		return cell;
	}

	function lambdaFacts(arguments:Array<AstArgument>, sourceBody:Array<AstStatement>, body:Array<AstStatement>,
			span:SourceSpan, outerContext:TypingContext):{
				free:Map<String, Bool>,
				freeAssigned:Map<String, Bool>,
				assigned:Map<String, Bool>,
				freeDeclarations:Map<String, String>
			} {
		function walked() {
			var free = FreeVariables.of(arguments, body);
			return {
				free: free.names,
				freeAssigned: free.assigned,
				assigned: AssignedDeclarations.ofFunction(arguments, body).declarations,
				freeDeclarations: free.declarations
			};
		}
		var resolution = outerContext.resolution;
		var resolved = resolution == null ? null : resolution.lambdaFacts(span.start);
		if (resolved == null)
			return walked();
		if (body != sourceBody) {
			var parameters:Map<String, String> = [
				for (argument in arguments) argument.name => compiler.types.analysis.BindingWalker.key(argument.name,
					argument.span)
			];
			var prologue = body.slice(0, body.length - sourceBody.length);
			for (declaration in AssignedDeclarations.within(prologue, parameters).declarations.keys())
				resolved.assigned.set(declaration, true);
		}
		if (session.checkResolution) {
			var expected = walked();
			for (part in ["free", "freeAssigned", "assigned"]) {
				var mine = part == "free" ? resolved.free : part == "freeAssigned"
					? resolved.freeAssigned : resolved.assigned,
					theirs = part == "free" ? expected.free : part == "freeAssigned"
						? expected.freeAssigned : expected.assigned;
				for (key in theirs.keys())
					if (!mine.exists(key))
						throw new InternalError('--check-resolution: the lambda at ${span.start} in ${outerContext.name} has $part "$key" by its walk but not by the resolution',
							span);
				for (key in mine.keys())
					if (!theirs.exists(key))
						throw new InternalError('--check-resolution: the lambda at ${span.start} in ${outerContext.name} has $part "$key" by the resolution but not by its walk',
							span);
			}
		}
		return resolved;
	}

	public function typeLambda(arguments:Array<AstArgument>, body:Array<AstStatement>, identity:String, span:SourceSpan,
			scope:Scope,
			expectedType:Null<CompilerType>, inferDynamicLambdaResult:Bool,
			outerContext:TypingContext):TypedExpression {
		var lambdaKey = '${outerContext.name}:${span.file.path}:${span.start}';
		var expectedFunction = expectedFunctionType(expectedType),
			inferContextualResult = expectedFunction != null && (switch (expectedFunction.result) {
				case TDynamic: true;
				default: false;
			}) && inferDynamicLambdaResult;
		if (expectedFunction != null && expectedFunction.arguments.length != arguments.length)
			fail("E1008", 'Lambda expects ${expectedFunction.arguments.length} arguments, got ${arguments.length}',
				span);
		var lambdaArguments:Array<{name:String, type:CompilerType}> = [],
			lambdaScope = new Scope();
		for (i in 0...arguments.length) {
			var argument = arguments[i],
				localName = argument.name == "_" ? '$' + 'discard:$i' : argument.name;
			var argumentType = (switch (argument.type) {
				case InferredType: true;
				default: false;
			}) ? (expectedFunction == null ? null : expectedFunction.arguments[i]) : bodyTyper.lowerType(argument.type,
				argument.span);
			if (argumentType != null
				&& (switch (argument.type) {
					case InferredType: false;
					default: true;
				})
					&& compiler.syntax.AstPredicates.isNullableArgument(argument))
					argumentType = switch argumentType {
				case TNullable(_): argumentType;
				default: TNullable(argumentType);
			};
			if (argumentType == null)
				fail("E1003", 'Cannot infer lambda parameter "${argument.name}" without a function context',
					argument.span);
			// A lambda has no direct entry: it takes `Null<T>` for an argument with a value default and fills it itself.
			var declaredType = argumentType;
			if (DefaultArguments.valueDefault(argument, argumentType, session.relations))
				argumentType = TNullable(argumentType);
			if (expectedFunction != null && !TypeRelations.equals(argumentType, expectedFunction.arguments[i])
				&& !TypeRelations.equals(declaredType, expectedFunction.arguments[i]))
				fail("E1003", "Lambda argument type does not match its context", argument.span);
			lambdaArguments.push({
				name: lambdaScope.define(localName, argumentType, argument.span).id,
				type: argumentType
			});
		}
		var sourceBody = body;
		body = DefaultArguments.withPrologue(arguments, [for (argument in lambdaArguments) argument.type], body,
			session.relations);
		var facts = lambdaFacts(arguments, sourceBody, body, span, outerContext),
			freeVariables = facts.free,
			lambdaAssignments:Map<String, Bool> = [];
		// The local a free name of the lambda refers to: its declaration's binding, or the receiver for `this`.
		function freeBinding(name:String):Null<LocalBinding> {
			var key = facts.freeDeclarations.get(name),
				found = name == "this" ? scope.receiverBinding() : key == null ? null : scope.bindingOf(key);
			if (session.checkResolution && found != scope.lookup(name))
				throw new InternalError('--check-resolution: the lambda at ${span.start} in ${outerContext.name} captures a different "$name" by its declaration than by its name',
					span);
			return found;
		}
		for (name in facts.freeAssigned.keys()) {
			var written = freeBinding(name);
			if (written != null)
				lambdaAssignments.set(written.declaration, true);
		}
		// An unqualified instance method in a lambda is resolved through the lexical receiver even without a `this` reference in the syntax.
		if (scope.receiverBinding() != null)
			for (name in freeVariables.keys())
				if (freeBinding(name) == null) {
					var method = bodyTyper.lexicalMethod(name),
						receiverType = scope.receiverType();
					if (method != null && !method.isStatic || receiverType != null
						&& bodyTyper.findFieldType(receiverType, name) != null)
						freeVariables.set("this", true);
				}
		var pathConstants:Map<String, String> = [],
			freeBindings:Map<String, LocalBinding> = [],
			captures:Array<TypedCapture> = [],
			captureCells:Map<String, String> = [],
			captureTypes:Map<String, CompilerType> = [];
		// Map iteration order differs between hosts; sort so closure layouts are deterministic.
		var freeNames = [for (name in freeVariables.keys()) name];
		freeNames.sort(Reflect.compare);
		for (name in freeNames) {
			var binding = freeBinding(name);
			if (binding != null) {
				freeBindings.set(name, binding);
				var constant = binding.keyPathConstant;
				if (constant != null) {
					pathConstants.set(name, constant);
					continue;
				}
				// A closure that only reads a local sees whatever it holds when the closure is created, so it must be assigned by then.
				if (!facts.freeAssigned.exists(name) && !scope.isAssignedBinding(binding))
					fail("E1023", 'Local "$name" may be used before assignment', span);
				var captureType:CompilerType = scope.typeOf(binding);
				var declaredCaptureType = scope.declaredTypeOf(binding);
				var cellClass:Null<String> = session.currentContext.storage.cell(binding.id),
					capturedCell = scope.cellClassOf(binding);
				if (cellClass == null && scope.isCellCaptured(binding))
					cellClass = capturedCell;
				var captured = binding.declaration;
				if (cellClass == null
					&& (outerContext.assignedDeclarations.exists(captured) || lambdaAssignments.exists(captured))) {
					var newCellClass = '$' + 'cell:' + outerContext.name + ':' + name;
					cellClass = outerContext.storage.requestBinding(binding.id, newCellClass, MutableCapture,
						declaredCaptureType == null ? captureType : declaredCaptureType);
				}
				var bindingId = binding.id,
					captureSource:TypedCaptureSource = if (scope.isCellCaptured(binding))
						CaptureCellEnvironmentField(name,
						requiredCell(capturedCell, name)) else if (scope.isCaptured(binding))
						CaptureEnvironmentField(name) else if (cellClass != null) CaptureCellLocal(bindingId,
						cellClass) else if (binding.receiver) CaptureReceiver else CaptureLocal(bindingId);
				lambdaScope.defineCapture(name, captureType, span, cellClass != null, cellClass, bindingId,
					declaredCaptureType == null ? captureType : declaredCaptureType, binding.localFunction,
					binding.declaration);
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
		// A switch arm with several patterns is typed once per pattern, so one lambda position can capture different bindings:
		// each distinct set of captures is its own lambda, and the first keeps the name the position gives it.
		var constantIdentity =
			[for (name in freeNames) if (pathConstants.exists(name)) name + "=" + pathConstants.get(name)].join(",");
		var variantKey = lambdaKey + "|" + [for (capture in captures) capture.field + "=" + capture.bindingId].join(",")
			+ "|" + constantIdentity;
		if (session.counters.lambdaCache.exists(variantKey))
			return session.counters.lambdaCache.get(variantKey);
		var variant = session.counters.nextLambdaVariant(lambdaKey);
		if (variant > 0)
			identity = compiler.semantic.LambdaName.variant(identity, variant);
		var typedBodyScope = new Scope(), parameters:Array<LocalBinding> = [];
		for (i in 0...lambdaArguments.length) {
			var localName = arguments[i].name == "_" ? '$' + 'discard:$i' : arguments[i].name;
			var parameter = typedBodyScope.define(localName, lambdaArguments[i].type, arguments[i].span);
			parameters.push(parameter);
			var temporary = arguments[i].local;
			if (temporary != null)
				temporary.declaration = parameter.declaration;
			lambdaArguments[i] = {name: parameter.id, type: lambdaArguments[i].type};
		}
		for (capture in captures) {
			var binding = freeBindings.get(capture.field);
			typedBodyScope.defineCapture(capture.field, capture.type, span, captureCells.exists(capture.field),
				captureCells.get(capture.field), capture.bindingId, capture.storageType,
				binding == null ? null : binding.localFunction, binding == null ? null : binding.declaration);
		}
		for (name in freeNames) if (pathConstants.exists(name)) {
			// Like a capture, the same local as the one outside, with that declaration's identity.
			var outer = freeBindings.get(name);
			if (outer == null)
				throw new InternalError('Missing the binding of key path constant "$name"');
			typedBodyScope.define(name, scope.typeOf(outer), span, true, null, false, null,
				outer.declaration).keyPathConstant = pathConstants.get(name);
		}
		// A lambda that captures is named after what it captures too, so an edit that changes its environment makes a new
		// function with a new environment type: closures made before the edit keep the code that reads their environment.
		var capturedIdentity = compiler.semantic.LambdaName.withCaptures(identity, [for (capture in captures)
			capture.field + ":" + compiler.types.DeclarationIndex.typeKey(capture.storageType)]);
		var lambdaName = compiler.semantic.LambdaName.of(outerContext.name, capturedIdentity),
			lambdaContext = session.enterBody(lambdaName, outerContext.typeSubstitutions, null),
			context = session.currentContext;
		context.scope = typedBodyScope;
		context.receiver = typedBodyScope.receiverType();
		// A result that is an empty type variable (a callback's `T`, `CallResolver.openResult`) is the body's, as an unannotated
		// lambda's is: a statement body makes it Void, as in Haxe.
		var openResult:Null<CompilerType> = null;
		if (expectedFunction != null && !inferContextualResult
			&& compiler.types.Monomorphs.isUnbound(expectedFunction.result)) {
			openResult = expectedFunction.result;
			inferContextualResult = true;
		}
		context.expectedReturnType = expectedFunction == null
			|| inferContextualResult ? TVoid : expectedFunction.result;
		context.contextualVoidLambda = expectedFunction != null && (switch (expectedFunction.result) {
			case TVoid: true;
			default: false;
		});
		for (declaration in facts.assigned.keys())
			context.assignedDeclarations.set(declaration, true);
		for (declaration in lambdaAssignments.keys())
			context.assignedDeclarations.set(declaration, true);
		var outerResolution = outerContext.resolution,
			lambdaStorage = outerResolution == null ? null : StorageRequirements.ofLambda(outerResolution, span.start,
				session.mayHoldValue, session.mayBeKeyPath);
		// Syntax the typer built has no place in the body's resolution.
		if (lambdaStorage == null)
			lambdaStorage = StorageRequirements.ofBody(BodyResolution.of(arguments, body), session.mayHoldValue,
				session.mayBeKeyPath);
		for (binding in lambdaStorage.closureWrites.keys())
			context.storage.addClosureWrite(binding);
		for (capture in captures) {
			var captured = freeBindings.get(capture.field),
				declaration = captured == null ? null : captured.declaration;
			if (declaration != null && outerContext.storage.isClosureWrite(declaration))
				context.storage.addClosureWrite(declaration);
		}
		for (binding in lambdaStorage.mutableCaptures.keys())
			context.storage.request(binding, '$' + 'cell:' + lambdaName + ':' + BindingWalker.nameOf(binding),
				MutableCapture);
		for (binding in lambdaStorage.exceptionCells.keys())
			context.storage.request(binding, "$cell:" + lambdaName + ":" + BindingWalker.nameOf(binding),
				ExceptionEdge);
		for (i in 0...arguments.length)
			bodyTyper.bindCell(parameters[i], lambdaArguments[i].type);
		var typedBody = bodyTyper.typeStatements(body, typedBodyScope, expectedFunction == null
			|| inferContextualResult ? null : expectedFunction.result),
			inferredResult:CompilerType;
		if (expectedFunction != null && !inferContextualResult)
			inferredResult = expectedFunction.result;
		else {
			var contextualResult = context.inferredResult;
			inferredResult = contextualResult == null ? CompilerType.TVoid : contextualResult;
		}
		var variable = openResult;
		if (variable != null) {
			if (inferredResult.match(TVoid))
				compiler.types.Monomorphs.close(variable, TVoid);
			else
				compiler.types.Monomorphs.unify(inferredResult, variable);
		}
		context.expectedReturnType = inferredResult;
		var lambdaCells = copyMap(context.storage.cells),
			lambdaCellTypes = copyMap(context.storage.types),
			lambdaCellKinds = copyMap(context.storage.kinds);
		session.leaveBody(lambdaContext);
		if ((switch (inferredResult) {
			case TVoid: false;
			default: true;
		}) && !ControlFlow.returnsOnEveryPath(typedBody,
			function(type, cases) return bodyTyper.exhaustiveSwitch(type, cases)))
			fail("E1006", 'Function $lambdaName does not return on every path', span);
		var environment:Null<String> = null;
		if (captures.length > 0)
			environment = compiler.semantic.LambdaName.ENVIRONMENT_PREFIX
				+ '${session.currentContext.name}:$capturedIdentity';
		if (environment != null)
			session.closureConversion.addEnvironment(environment, captures);
		session.closureConversion.addFunction({
			name: lambdaName,
			role: LambdaFunction,
			origin: outerContext.name,
			originKind: compiler.types.TypedAst.FunctionOriginKind.Lambda,
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
				session.closureConversion.addCell(requiredMapValue(lambdaCells, name),
					requiredMapValue(lambdaCellTypes, name),
					requiredMapValue(lambdaCellKinds, name));
		var lambdaResult = new TypedExpression(TLambda(lambdaName, environment, captures),
			TFunction([for (argument in lambdaArguments) argument.type], inferredResult,
			FunctionTypes.ofArguments(arguments)),
			span);
		session.counters.lambdaCache.set(variantKey, lambdaResult);
		session.monomorphs.recordLambda(variantKey);
		return lambdaResult;
	}

	static function expectedFunctionType(type:Null<CompilerType>):Null<{
		arguments:Array<CompilerType>,
		result:CompilerType
	}> {
		if (type == null)
			return null;
		return switch type {
			case TFunction(arguments, result, _): {arguments: arguments, result: result};
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
			throw new InternalError('Missing map entry "$name"');
		return source.get(name);
	}

	@:noReturn
	static function fail(code:String, message:String, span:SourceSpan):Void
		throw new CompileError(new Diagnostic(code, message, span));
}
