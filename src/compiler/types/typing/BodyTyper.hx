package compiler.types.typing;

import compiler.syntax.Ast;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstFunction;
import compiler.syntax.Ast.AstStatement;
import compiler.syntax.Ast.AstType;
import compiler.syntax.Ast.AstClass;
import compiler.syntax.Ast.AstEnum;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;
import compiler.types.Type.AnonymousField;
import compiler.runtime.PlatformAbi;
import compiler.semantic.GenericSpecializationRegistry;
import compiler.types.typing.TypingSession.ResolvedInlineConstant;
import compiler.types.analysis.CaptureAnalysis;
import compiler.types.analysis.ControlFlow;
import compiler.types.analysis.FlowAnalysis;
import compiler.types.analysis.LexicalStorageAnalysis;
import compiler.types.analysis.Scope;
import compiler.semantic.SemanticProgram.SemanticMethodInfo;
import compiler.semantic.SemanticSignature;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedExpressionKind;
import compiler.types.TypedAst.TypedFunction;
import compiler.types.TypedAst.TypedClass;
import compiler.types.TypedAst.TypedField;
import compiler.types.TypedAst.TypedStatement;
import compiler.types.TypedAst.TypedSwitchBinding;
import compiler.types.TypedAst.TypedSwitchFieldAccess;
import compiler.types.TypedAst.TypedSwitchPredicate;
import compiler.types.TypedAst.TypedSwitchCase;
import compiler.types.TypedAst.TypedSwitchCoverageCase;
import compiler.types.TypedAst.TypedSwitchArrayPattern;
import compiler.types.TypedAst.TypedSwitchArrayElement;
import compiler.types.TypedAst.TypedSwitchObjectFieldAccess;
import compiler.Diagnostic;
import compiler.Diagnostic.CompileError;
import compiler.Source.SourceSpan;
import compiler.service.CancellationError;

/** Types function and expression bodies using the current compilation session. */
@:allow(compiler.types.typing.ProgramTyper)
@:allow(compiler.types.typing.WireCodecGenerator)
class BodyTyper {
	final session:TypingSession;
	final expressionTyper:ExpressionTyper;
	final closureTyper:ClosureTyper;
	final statementTyper:StatementTyper;
	final conversionResolver:ConversionResolver;
	final callResolver:CallResolver;
	final genericInstantiation:GenericInstantiation;
	final inlineConstantResolver:InlineConstantResolver;
	final anonymousTypeRegistry:AnonymousTypeRegistry;
	var context(get, never):TypingContext;

	inline function get_context():TypingContext
		return session.currentContext;

	inline function enterBody(name:String, ?typeSubstitutions:Map<String, CompilerType>, ?ownerOverride:String):TypingContext
		return session.enterBody(name, typeSubstitutions, ownerOverride);

	inline function leaveBody(body:TypingContext):Void
		session.leaveBody(body);

	public function new(externals:Null<Map<String, {arguments:Array<CompilerType>, result:CompilerType}>>,
			specializations:Null<GenericSpecializationRegistry>, ?nativeAbiTarget:String, tolerant:Bool = false, ?checkpoint:Void->Void) {
		this.session = new TypingSession(externals, specializations, nativeAbiTarget, tolerant, checkpoint);
		this.conversionResolver = new ConversionResolver(session);
		this.inlineConstantResolver = new InlineConstantResolver(session, function(owner, name) return this.findStaticFieldNullable(owner, name),
			function(expression, owner, name, expected, typeParameters) return this.typeInlineInitializer(expression, owner, name, expected, typeParameters),
			function(value, expected, context, code) return this.coerce(value, expected, context, code));
		this.anonymousTypeRegistry = new AnonymousTypeRegistry(session);
		this.closureTyper = new ClosureTyper(session,
			function(expression, scope, expected, inferDynamicLambdaResult) return this.typeExpression(expression, scope, expected, inferDynamicLambdaResult),
			function(type) return this.lowerType(type), function(name) return this.lexicalMethod(name),
			function(type, name) return this.findFieldType(type, name), function(name, scope) return this.boundCell(name, scope),
			function(name, substitutions, owner) return this.enterBody(name, substitutions, owner), function(body) this.leaveBody(body),
			function(name, span, scope, type) this.bindCell(name, span, scope, type),
			function(statements, scope, result) return this.typeStatements(statements, scope, result),
			function(statements) return ControlFlow.alwaysReturns(statements, function(type, cases) return this.exhaustiveEnum(type, cases)));
		var switchRules = {
			subjectBinding: function(value:AstExpression, expected:CompilerType, scope:Scope) return this.switchSubjectBinding(value, expected, scope),
			catchAll: function(value:AstExpression) return isSwitchCatchAll(value),
			enumPattern: function(value:AstExpression, expected:CompilerType, scope:Scope) return this.typeEnumPattern(value, expected, scope),
			arrayPattern: function(value:AstExpression, expected:CompilerType, scope:Scope) return this.typeSwitchArrayPattern(value, expected, scope),
			arrayPatternKey: function(pattern:TypedSwitchArrayPattern) return this.switchArrayPatternKey(pattern),
			caseKey: function(value:TypedExpression, predicates:Array<TypedSwitchPredicate>) return this.switchCaseKey(value, predicates),
			enumCaseCovered: function(type:CompilerType, index:Int, cases:Array<TypedSwitchCoverageCase>) return this.enumCaseCovered(type, index, cases),
			enumLiteral: function(value:TypedExpression) return enumLiteral(value),
			isEnum: function(type:CompilerType) return isEnum(type),
			isNullableEnum: function(type:CompilerType) return isNullableEnum(type),
			enumName: function(type:CompilerType) return enumName(type)
		};
		this.genericInstantiation = new GenericInstantiation(session,
			function(expression, scope, expected, inferDynamicLambdaResult) return this.typeExpression(expression, scope, expected, inferDynamicLambdaResult),
			function(value, expected, context, code) return this.coerce(value, expected, context, code),
			function(arguments, expected, name) return this.coerceArguments(arguments, expected, name),
			function(argument, substitutions) return this.argumentType(argument, substitutions),
			function(expression, expected, declarationName) return this.typeDefaultExpression(expression, expected, declarationName),
			function(span) return this.posInfosExpression(span),
			function(fn, owner, isStatic, substitutions, specializedName,
					abstractReceiver) return this.typeFunction(fn, owner, isStatic, substitutions, specializedName, abstractReceiver));
		this.callResolver = new CallResolver(session, genericInstantiation,
			function(expression, scope, expected, inferDynamicLambdaResult) return this.typeExpression(expression, scope, expected, inferDynamicLambdaResult),
			function(value, expected, context, code) return this.coerce(value, expected, context, code),
			function(argument, substitutions) return this.argumentType(argument, substitutions), function(span) return this.posInfosExpression(span),
			function(expression, expected, declarationName) return this.typeDefaultExpression(expression, expected, declarationName), functionTypeParameters,
			function(pattern, actual, parameters, substitutions,
					span) this.genericInstantiation.inferTypeParameters(pattern, actual, parameters, substitutions, span),
			inheritanceName, function(type, name) return this.findFieldType(type, name),
			function(receiver, name, span) return this.typedMember(receiver, name, span), function(type) return this.lowerType(type),
			function(type, span) return this.arrayElementType(type, span), function(name, span, scope) return this.resolveReceiver(name, span, scope),
			function(receiver, name, span, scope) return this.typedMemberWithFlow(receiver, name, span, scope));
		this.expressionTyper = new ExpressionTyper(session, conversionResolver, callResolver,
			function(expression, scope, expected, inferDynamicLambdaResult) return this.typeExpression(expression, scope, expected, inferDynamicLambdaResult),
			function(value, expected, context, code) return this.coerce(value, expected, context, code), switchRules, anonymousTypeRegistry,
			function(type, span) return this.arrayElementType(type, span), function(type) return this.lowerType(type), {
				variable: function(name, span, scope, expected) return this.typeVariableExpression(name, span, scope, expected),
				lambda: function(arguments, body, span, scope, expected,
						inferDynamicLambdaResult) return this.closureTyper.typeLambda(arguments, body, span, scope, expected, inferDynamicLambdaResult,
						session.currentContext),
				member: function(object, name, span, scope) return this.typeMember(object, name, span, scope),
				block: function(statements, result, span, scope, expected) return this.typeBlockExpression(statements, result, span, scope, expected),
				methodCall: function(object, name, arguments, span, scope, expected) return this.typeMethodCall(object, name, arguments, span, scope, expected),
				contextualType: function(expression, scope) return this.contextualExpressionType(expression, scope)
			});
		this.statementTyper = new StatementTyper(session,
			function(expression, scope, expected, inferDynamicLambdaResult) return this.typeExpression(expression, scope, expected, inferDynamicLambdaResult),
			function(value, expected, context, code) return this.coerce(value, expected, context, code),
			function(name, initializer, statements, start) return this.expectedInitializerType(name, initializer, statements, start),
			function(name, span, scope, type) this.bindCell(name, span, scope, type),
			function(statements, scope, result) return this.typeStatements(statements, scope, result),
			function(type, cases) return this.exhaustiveEnum(type, cases), function(type) return this.lowerType(type), unwrapNullable,
			CallResolver.mapKeyIteratorSource, switchRules, {
				findStaticField: function(owner, name) return this.findStaticFieldNullable(owner, name),
				requireStaticField: function(owner, name, span) return this.findStaticField(owner, name, span),
				rejectInlineFieldMutation: function(owner, name, span) this.rejectInlineFieldMutation(owner, name, span),
				findFieldType: function(type, name) return this.findFieldType(type, name),
				instancePropertyAccessor: function(type, name, read) return this.instancePropertyAccessor(type, name, read),
				fieldType: function(type, name, span) return this.fieldType(type, name, span),
				fieldRepresentationType: function(type, name, span) return session.representation.resolveField(type, name, span).physical,
				abiBoundaryCast: function(value, target) return session.representation.boundaryCast(value, target),
				arrayElementType: function(type, span) return this.arrayElementType(type, span),
				boundCell: function(name, scope) return this.boundCell(name, scope)
			});
	}

	public function recoveryDiagnostics():Array<Diagnostic>
		return session.recoveryDiagnostics.copy();

	function rememberRecoveryError(error:Dynamic, span:SourceSpan):Void {
		if (Std.isOfType(error, CompileError)) {
			var compileError:CompileError = cast error;
			session.rememberRecoveryDiagnostic(compileError.diagnostic);
		} else
			session.rememberRecoveryDiagnostic(new Diagnostic("E0002", "Unable to type recovered function", span));
	}

	static function declarationTypeSubstitutions(owner:String, parameters:Array<String>):Map<String, CompilerType> {
		var result:Map<String, CompilerType> = [];
		for (parameter in parameters)
			result.set(parameter, TTypeParameter(owner, parameter));
		return result;
	}

	function inferNoReturnFunctions():Void {
		var changed = true;
		while (changed) {
			changed = false;
			for (name => fn in session.signatures)
				if (!session.noReturnFunctions.exists(name) && astStatementsDoNotReturn(fn.statements, name)) {
					session.noReturnFunctions.set(name, true);
					changed = true;
				}
		}
	}

	function astStatementsDoNotReturn(statements:Array<AstStatement>, functionName:String):Bool {
		for (statement in statements)
			switch statement {
				case Throw(_, _):
					return true;
				case Expression(expression, _):
					switch expression {
						case Call(name, _, _): return session.noReturnFunctions.exists(qualifiedLocalCall(name, functionName));
						default: return false;
					}
				case If(_, yes, no, _) if (no.length > 0
					&& astStatementsDoNotReturn(yes, functionName)
					&& astStatementsDoNotReturn(no, functionName)):
					return true;
				case Switch(_, cases, fallback, hasDefault, _) if (hasDefault && astStatementsDoNotReturn(fallback, functionName)):
					var allExit = true;
					for (switchCase in cases)
						if (!astStatementsDoNotReturn(switchCase.statements, functionName))
							allExit = false;
					if (allExit)
						return true;
					return false;
				case VarDeclaration(_, _, _, _), UninitializedDeclaration(_, _, _), Assignment(_, _, _), IndexAssignment(_, _, _, _),
					FieldAssignment(_, _, _, _), Increment(_, _, _):
					// Continue through statements which cannot transfer control.
				default:
					return false;
			}
		return false;
	}

	static function qualifiedLocalCall(name:String, functionName:String):String {
		if (name.indexOf(".") >= 0)
			return name;
		var cursor = functionName.length - 1;
		while (cursor >= 0) {
			if (functionName.charCodeAt(cursor) == 46)
				return functionName.substring(0, cursor) + "." + name;
			cursor--;
		}
		return name;
	}

	static function parentPath(path:String):Null<String> {
		return compiler.QualifiedName.parent(path);
	}

	static function pathBeforeLast(path:String):String {
		var parent = parentPath(path);
		return parent == null ? "" : parent;
	}

	static function lastPathSegment(path:String):String {
		return compiler.QualifiedName.last(path);
	}

	static function splitPath(path:String):Array<String> {
		return compiler.QualifiedName.split(path);
	}

	static function enumName(type:Null<CompilerType>):Null<String> {
		return switch enumInstance(type) {
			case TInstance(Enum, name, _): name;
			case _: null;
		};
	}

	static function enumInstance(type:Null<CompilerType>):Null<CompilerType>
		return switch type {
			case TInstance(Enum, _, _): type;
			case TNullable(element), TAbstract(_, _, element): enumInstance(element);
			case _: null;
		};

	static function expectedFunctionType(type:Null<CompilerType>):Null<{arguments:Array<CompilerType>, result:CompilerType}> {
		if (type == null)
			return null;
		return switch type {
			case TFunction(arguments, result): {arguments: arguments, result: result};
			case TNullable(inner): expectedFunctionType(inner);
			default: null;
		};
	}

	static function requiredExpression(value:Null<TypedExpression>):TypedExpression {
		if (value == null)
			throw "Expected typed expression";
		return value;
	}

	static function requiredString(value:Null<String>):String {
		if (value == null)
			throw "Expected string";
		return value;
	}

	static function requiredStrings(value:Null<Array<String>>):Array<String> {
		if (value == null)
			throw "Expected string array";
		return value;
	}

	static function requiredType(value:Null<CompilerType>):CompilerType {
		if (value == null)
			throw "Expected semantic type";
		return value;
	}

	static function requiredFunction(value:Null<AstFunction>):AstFunction {
		if (value == null)
			throw "Expected function declaration";
		return value;
	}

	function typeFunction(fn:AstFunction, ?owner:String, isStatic:Bool = false, ?substitutions:Map<String, CompilerType>, ?specializedName:String,
			?abstractReceiver:CompilerType):TypedFunction {
		if (!session.tolerant)
			return typeFunctionBody(fn, owner, isStatic, substitutions, specializedName, abstractReceiver);
		var contextDepth = session.bodyContexts.length;
		try {
			return typeFunctionBody(fn, owner, isStatic, substitutions, specializedName, abstractReceiver);
		}
		catch (error:Dynamic) {
			while (session.bodyContexts.length > contextDepth)
				session.leaveBody(session.currentContext);
			if (Std.isOfType(error, CancellationError))
				throw error;
			rememberRecoveryError(error, fn.span);
			return recoveredFunctionSkeleton(fn, owner, isStatic, substitutions, specializedName);
		}
	}

	function recoveredFunctionSkeleton(fn:AstFunction, owner:Null<String>, isStatic:Bool,
			substitutions:Null<Map<String, CompilerType>>, specializedName:Null<String>):TypedFunction {
		var functionName = specializedName == null ? (owner == null ? fn.name : owner + "." + fn.name) : specializedName,
			arguments = [
				for (argument in fn.arguments)
					{name: argument.name, type: argumentType(argument, substitutions)}
			],
			result = resolveType(fn.result, substitutions),
			isConstructor = owner != null && session.classDecls.exists(owner) && fn.name == "new";
		return {
			name: functionName,
			genericOrigin: specializedName == null ? null : (owner == null ? fn.name : owner + "." + fn.name),
			owner: owner,
			isStatic: isStatic,
			isConstructor: isConstructor,
			arguments: arguments,
			result: result,
			statements: [],
			cells: [],
			cellCaptures: [],
			span: fn.span
		};
	}

	function typeFunctionBody(fn:AstFunction, ?owner:String, isStatic:Bool = false, ?substitutions:Map<String, CompilerType>, ?specializedName:String,
			?abstractReceiver:CompilerType):TypedFunction {
		var functionName = specializedName == null ? (owner == null ? fn.name : owner + "." + fn.name) : specializedName;
		for (argument in fn.arguments) {
			var argumentValueType = argumentType(argument, substitutions);
			if (compiler.ffi.NativeLayout.containsNativeLayoutType(argumentValueType)) {
				if (!session.tolerant)
					fail("E1022", 'Native layout type "$argumentValueType" cannot be passed or stored as a Haxe runtime value yet', argument.span);
				session.rememberRecoveryDiagnostic(new Diagnostic("E1022",
					'Native layout type "$argumentValueType" cannot be passed or stored as a Haxe runtime value yet', argument.span));
			}
		}
		var result = resolveType(fn.result, substitutions);
		if (compiler.ffi.NativeLayout.containsNativeLayoutType(result)) {
			if (!session.tolerant)
				fail("E1022", 'Native layout type "$result" cannot be returned as a Haxe runtime value yet', fn.span);
			session.rememberRecoveryDiagnostic(new Diagnostic("E1022",
				'Native layout type "$result" cannot be returned as a Haxe runtime value yet', fn.span));
		}
		var functionContext = enterBody(functionName, substitutions, specializedName == null ? null : owner);
		var storage = CaptureAnalysis.analyze(fn.statements, [for (argument in fn.arguments) argument.name]);
		var lexicalStorage = LexicalStorageAnalysis.analyze(fn.statements, fn.arguments);
		for (name in storage.assigned.keys())
			context.assigned.set(name, true);
		for (binding in lexicalStorage.mutableCaptures.keys()) {
			context.storage.request(binding, '$' + 'cell:' + context.name + ':' + binding, MutableCapture);
		}
		for (binding in lexicalStorage.exceptionCells.keys()) {
			context.storage.request(binding, '$' + 'cell:' + context.name + ':' + binding, ExceptionEdge);
		}
		var scope = new Scope();
		context.scope = scope;
		var isConstructor = owner != null && session.classDecls.exists(owner) && fn.name == "new";
		if (abstractReceiver != null) {
			scope.defineReceiver(abstractReceiver, fn.span);
		} else if (owner != null && !isStatic) {
			scope.defineReceiver(session.representation.receiverType(owner, context.typeSubstitutions), fn.span);
		}
		context.receiver = scope.resolve("this");
		var arguments:Array<{name:String, type:CompilerType}> = [];
		if (abstractReceiver != null)
			arguments.push({name: "this", type: abstractReceiver});
		for (argument in fn.arguments) {
			var type = argumentType(argument, substitutions);
			scope.define(argument.name, type, argument.span);
			bindCell(argument.name, argument.span, scope, type);
			arguments.push({name: scope.requireId(argument.name), type: type});
		}
		context.expectedReturnType = result;
		inferBodyLocalTypes(fn.statements, result);
		var statements = typeStatements(fn.statements, scope, result);
		if (!session.tolerant
			&& result != TVoid
			&& !ControlFlow.alwaysReturns(statements, function(type, cases) return this.exhaustiveEnum(type, cases)))
			fail("E1006", 'Function ${fn.name} does not return on every path', fn.span);
		var typeArguments:Null<Array<CompilerType>> = null,
			typeParameters = fn.typeParameters;
		if (specializedName != null && typeParameters != null) {
			var resolvedArguments:Array<CompilerType> = [];
			for (parameter in typeParameters) {
				if (!context.typeSubstitutions.exists(parameter))
					throw 'Missing specialization for type parameter "$parameter"';
				resolvedArguments.push(context.typeSubstitutions.get(parameter));
			}
			typeArguments = resolvedArguments;
		}
		var resultFunction:TypedFunction = {
			name: functionName,
			genericOrigin: specializedName == null ? null : (owner == null ? fn.name : owner + "." + fn.name),
			typeArguments: typeArguments,
			owner: owner,
			isStatic: isStatic,
			isConstructor: isConstructor,
			arguments: arguments,
			result: result,
			statements: statements,
			cells: copyMap(context.storage.cells),
			cellCaptures: [],
			span: fn.span
		};
		for (name in context.storage.cells.keys()) {
			if (context.storage.types.exists(name) && context.storage.kinds.exists(name))
				session.closureConversion.addCell(requiredMapValue(context.storage.cells, name), requiredMapValue(context.storage.types, name),
					requiredMapValue(context.storage.kinds, name));
		}
		leaveBody(functionContext);
		return resultFunction;
	}

	function boundCell(name:String, scope:Scope):Null<String> {
		var id = scope.resolveId(name);
		return id == null ? null : context.storage.cell(id);
	}

	function bindCell(name:String, span:SourceSpan, scope:Scope, type:CompilerType):Void {
		var id = scope.requireId(name);
		context.storage.bind(LexicalStorageAnalysis.key(name, span), id, type);
	}

	function typeStatements(statements:Array<AstStatement>, scope:Scope, result:Null<CompilerType>):Array<TypedStatement> {
		session.checkpoint();
		if (session.tolerant)
			return typeStatementsRecovering(statements, scope, result);
		return typeStatementsStrict(statements, scope, result);
	}

	function typeStatementsRecovering(statements:Array<AstStatement>, scope:Scope, result:Null<CompilerType>):Array<TypedStatement> {
		var output:Array<TypedStatement> = [];
		for (statement in statements) {
			var checkpoint = scope.checkpoint();
			try {
				output = output.concat(typeStatementsStrict([statement], scope, result));
			} catch (error:Dynamic) {
				// Strict typing may have defined a local, refined a flow fact, or
				// consumed a binding id before a later child failed. Recovery must
				// retry from the pre-statement lexical state, otherwise the failed
				// subtree can poison all following statements.
				scope.rollback(checkpoint);
				if (Std.isOfType(error, CancellationError))
					throw error;
				if (Std.isOfType(error, CompileError)) {
					var compileError:CompileError = cast error;
					session.rememberRecoveryDiagnostic(compileError.diagnostic);
				} else
					rememberRecoveryError(error, statementSpan(statement));
				var recovered:Null<TypedStatement> = null;
				try {
					recovered = recoverDeclaration(statement, scope);
					} catch (recoveryError:Dynamic) {
						if (Std.isOfType(recoveryError, CancellationError))
							throw recoveryError;
						scope.rollback(checkpoint);
						rememberRecoveryError(recoveryError, statementSpan(statement));
					}
				if (recovered == null)
					try {
						recovered = recoverCompoundStatement(statement, scope, result);
					} catch (recoveryError:Dynamic) {
						if (Std.isOfType(recoveryError, CancellationError))
							throw recoveryError;
						scope.rollback(checkpoint);
						rememberRecoveryError(recoveryError, statementSpan(statement));
					}
				if (recovered != null)
					output.push(recovered);
				else {
					retainRecoveredDeclaration(statement, scope);
					var span = statementSpan(statement);
					output.push(TExpression(new TypedExpression(TNullLiteral, TError, span), span));
				}
			}
		}
		return output;
	}

	/** Keep a declaration-shaped typed node when its initializer failed locally. */
	function recoverDeclaration(statement:AstStatement, scope:Scope):Null<TypedStatement> {
		return switch statement {
			case UninitializedDeclaration(name, declared, span):
				var type = recoveredDeclarationType(name, declared, scope),
					id = recoverDeclarationBinding(name, type, span, scope);
				TDeclare(id, type, span);
			case VarDeclaration(name, declared, _, span):
				var type = recoveredDeclarationType(name, declared, scope),
					id = recoverDeclarationBinding(name, type, span, scope),
					value = new TypedExpression(TNullLiteral, type, span);
				TVar(id, value, span);
			default: null;
		};
	}

	function recoveredDeclarationType(name:String, declared:Null<AstType>, scope:Scope):CompilerType {
		if (declared != null)
			return resolveType(declared);
		var existing = scope.resolveDeclared(name);
		return existing == null ? TUnknown : existing;
	}

	function recoverDeclarationBinding(name:String, type:CompilerType, span:SourceSpan, scope:Scope):String {
		var id = scope.resolveId(name);
		if (id == null) {
			try {
				scope.define(name, type, span);
			}
			catch (_:Dynamic) {}
			id = scope.resolveId(name);
		}
		if (id == null)
			throw 'Missing recovered binding for "$name"';
		return id;
	}

	function retainRecoveredDeclaration(statement:AstStatement, scope:Scope):Void {
		switch statement {
			case UninitializedDeclaration(name, _, span), VarDeclaration(name, _, _, span):
				try {
					scope.define(name, TUnknown, span);
				} catch (_:Dynamic) {}
			default:
		}
	}

	/** Preserve nested scopes when a compound statement fails before its body is typed. */
	function recoverCompoundStatement(statement:AstStatement, scope:Scope, result:Null<CompilerType>):Null<TypedStatement> {
		switch statement {
			case If(predicate, thenBranch, elseBranch, span):
				var typedCondition = typeExpression(predicate, scope, null, false),
					thenScope = recoveredBranchScope(scope, typedCondition, true),
					elseScope = recoveredBranchScope(scope, typedCondition, false);
				return TIf(typedCondition, typeStatements(thenBranch, thenScope, result),
					typeStatements(elseBranch, elseScope, result), span);
			case While(predicate, body, span):
				var typedCondition = typeExpression(predicate, scope, null, false);
				var context = session.currentContext;
				context.loopEarlyExits[context.loopDepth] = true;
				context.loopDepth++;
				var typedBody:Array<TypedStatement>;
				try {
					typedBody = typeStatements(body, new Scope(scope), result);
				} catch (error:Dynamic) {
					context.loopDepth--;
					throw error;
				}
				context.loopDepth--;
				return TWhile(typedCondition, typedBody, span);
			case DoWhile(body, predicate, span):
				var context = session.currentContext;
				context.loopEarlyExits[context.loopDepth] = false;
				context.loopDepth++;
				var bodyScope = new Scope(scope),
					typedBody:Array<TypedStatement>;
				try {
					typedBody = typeStatements(body, bodyScope, result);
				} catch (error:Dynamic) {
					context.loopDepth--;
					throw error;
				}
				context.loopDepth--;
				var typedCondition = typeExpression(predicate, bodyScope, null, false);
				return TDoWhile(typedBody, typedCondition, span);
			case ForIn(name, valueName, iterable, body, span):
				var typedIterable = unwrapNullable(typeExpression(iterable, scope, null, false)),
					originalIterable = typedIterable,
					element = recoveredForInElement(originalIterable, valueName),
					loopScope = new Scope(scope);
				loopScope.define(name, element, span);
				bindCell(name, span, loopScope, element);
				if (valueName != null) {
					var value = recoveredForInValue(originalIterable);
					loopScope.define(valueName, value, span);
					bindCell(valueName, span, loopScope, value);
				}
				var context = session.currentContext;
				context.loopEarlyExits[context.loopDepth] = true;
				context.loopDepth++;
				var typedBody:Array<TypedStatement>;
				try {
					typedBody = typeStatements(body, loopScope, result);
				} catch (error:Dynamic) {
					context.loopDepth--;
					throw error;
				}
				context.loopDepth--;
				var loopIterable = switch originalIterable.type {
					case TMap(_, value) if (valueName == null):
						new TypedExpression(TCollectionCall(originalIterable, "values", []), TArray(value), span);
					default: originalIterable;
				};
				return TForIn(loopScope.requireId(name), valueName == null ? null : loopScope.requireId(valueName),
					loopIterable, typedBody, span);
			case Try(tryBranch, catches, span):
				var typedCatches = [],
					typedTry = typeStatements(tryBranch, new Scope(scope), result);
				for (caught in catches) {
					var catchType = resolveType(caught.type),
						catchScope = new Scope(scope);
					catchScope.define(caught.name, catchType, caught.span);
					bindCell(caught.name, caught.span, catchScope, catchType);
					typedCatches.push({
						name: catchScope.requireId(caught.name),
						type: catchType,
						statements: typeStatements(caught.statements, catchScope, result),
						span: caught.span
					});
				}
				return TTry(typedTry, typedCatches, span);
			case Switch(expression, cases, defaultBranch, hasDefault, span):
				var typedSubject = typeExpression(expression, scope, null, false),
					invalidSubject = !TypeRelations.equals(typedSubject.type, TInt)
						&& !TypeRelations.equals(typedSubject.type, TString)
						&& !isEnum(typedSubject.type),
					caseExpected = invalidSubject ? null : typedSubject.type,
					typedCases = [];
				for (switchCase in cases) {
					var caseScope = new Scope(scope),
						subjectBinding:Null<String> = null,
						isCatchAll = isSwitchCatchAll(switchCase.value),
						pattern:Null<{
							value:TypedExpression,
							enumName:String,
							index:Int,
							bindings:Array<TypedSwitchBinding>,
							predicates:Array<TypedSwitchPredicate>
						}> = null;
					if (!invalidSubject) {
						try {
							subjectBinding = switchSubjectBinding(switchCase.value, typedSubject.type, caseScope);
						} catch (error:Dynamic) {
							if (Std.isOfType(error, CancellationError))
								throw error;
							rememberRecoveryError(error, expressionSpan(switchCase.value));
						}
					}
					if (!invalidSubject && subjectBinding == null && !isCatchAll)
						pattern = recoverSwitchPattern(switchCase.value, typedSubject.type, caseScope);
					var typedValue = isCatchAll || subjectBinding != null ? typedSubject : pattern == null
						? typeExpression(switchCase.value, caseScope, caseExpected, false) : pattern.value,
						typedGuard = switchCase.guard == null ? null : recoverCoerce(typeExpression(switchCase.guard, caseScope, TBool, false), TBool,
							"switch guard", "E1003");
					if (typedGuard != null)
						caseScope = FlowAnalysis.narrowedScope(caseScope, typedGuard, true);
					typedCases.push({
						value: typedValue,
						subjectBinding: subjectBinding,
						isCatchAll: isCatchAll,
						guard: typedGuard,
						statements: typeStatements(switchCase.statements, caseScope, result),
						enumName: pattern == null ? null : pattern.enumName,
						constructorIndex: pattern == null ? -1 : pattern.index,
						bindings: pattern == null ? [] : pattern.bindings,
						predicates: pattern == null ? [] : pattern.predicates,
						span: switchCase.span
					});
				}
				return TSwitch(typedSubject, typedCases,
					typeStatements(defaultBranch, new Scope(scope), result), hasDefault, span);
			default:
				return null;
		}
	}

	function recoverSwitchPattern(value:AstExpression, expected:CompilerType, scope:Scope):Null<{
		value:TypedExpression,
		enumName:String,
		index:Int,
		bindings:Array<TypedSwitchBinding>,
			predicates:Array<TypedSwitchPredicate>
		}> {
		try {
			return typeEnumPattern(value, expected, scope);
		} catch (error:Dynamic) {
			if (Std.isOfType(error, CancellationError))
				throw error;
			rememberRecoveryError(error, expressionSpan(value));
			return null;
		}
	}

	function recoverCoerce(value:TypedExpression, expected:CompilerType, contextName:String, code:String):TypedExpression {
		try {
			return coerce(value, expected, contextName, code);
		} catch (error:Dynamic) {
			if (Std.isOfType(error, CancellationError))
				throw error;
			rememberRecoveryError(error, value.span);
			return new TypedExpression(TNullLiteral, TError, value.span);
		}
	}

	function recoveredBranchScope(scope:Scope, condition:TypedExpression, positive:Bool):Scope {
		return TypeRelations.equals(condition.type, TBool)
			? FlowAnalysis.narrowedScope(scope, condition, positive)
			: new Scope(scope);
	}

	function recoveredForInElement(iterable:TypedExpression, valueName:Null<String>):CompilerType {
		return switch iterable.type {
			case TArray(element), TIterator(element): element;
			case TRange: TInt;
			case TMap(key, value): valueName == null ? value : key;
			default: TUnknown;
		};
	}

	function recoveredForInValue(iterable:TypedExpression):CompilerType
		return switch iterable.type {
			case TMap(_, value): value;
			default: TUnknown;
		};

	function typeStatementsStrict(statements:Array<AstStatement>, scope:Scope, result:Null<CompilerType>):Array<TypedStatement> {
		var output = [];
		for (statementIndex in 0...statements.length) {
			var statement = statements[statementIndex];
			if (ControlFlow.alwaysReturns(output, function(type, cases) return this.exhaustiveEnum(type, cases))) {
				if (isNoReturnPlaceholder(output, statement))
					continue;
				fail("E1012", "Unreachable statement", statementSpan(statement));
			}
			var simpleStatement = statementTyper.typeSimpleStatement(statement, scope, result, statements, statementIndex);
			if (simpleStatement != null) {
				for (typedStatement in simpleStatement)
					output.push(typedStatement);
				continue;
			}
			switch statement {
				case ErrorStatement(_):
					throw "Simple statement was not dispatched";
				case UninitializedDeclaration(_, _, _):
					throw "Simple statement was not dispatched";
				case VarDeclaration(_, _, _, _):
					throw "Simple statement was not dispatched";
				case Return(expression, span):
					throw "Simple statement was not dispatched";
				case ReturnVoid(span):
					throw "Simple statement was not dispatched";
				case Throw(expression, span):
					throw "Simple statement was not dispatched";
				case Try(tryBranch, catches, span):
					output.push(statementTyper.typeTry(tryBranch, catches, span, scope, result));
				case Break(span):
					throw "Simple statement was not dispatched";
				case Continue(span):
					throw "Simple statement was not dispatched";
				case Increment(name, delta, span):
					output.push(statementTyper.typeIncrement(name, delta, span, scope));
				case Assignment(name, expression, span):
					output.push(statementTyper.typeAssignment(name, expression, span, scope));
				case IndexAssignment(array, offset, expression, span):
					output.push(statementTyper.typeIndexAssignment(array, offset, expression, span, scope));
				case FieldAssignment(receiverExpression, fieldName, expression, span):
					output.push(statementTyper.typeFieldAssignment(receiverExpression, fieldName, expression, span, scope));
				case If(predicate, thenBranch, elseBranch, span):
					output.push(statementTyper.typeIf(predicate, thenBranch, elseBranch, span, scope, result));
				case While(predicate, body, span):
					output.push(statementTyper.typeWhile(predicate, body, span, scope, result));
				case DoWhile(body, predicate, span):
					output.push(statementTyper.typeDoWhile(body, predicate, span, scope, result));
				case ForIn(name, valueName, iterable, body, span):
					output.push(statementTyper.typeForIn(name, valueName, iterable, body, span, scope, result));
				case Switch(expression, cases, defaultBranch, hasDefault, span):
					output.push(statementTyper.typeSwitch(expression, cases, defaultBranch, hasDefault, span, scope, result));
				case Expression(expression, span):
					throw "Simple statement was not dispatched";
			}
		}
		return output;
	}

	static function isNoReturnPlaceholder(output:Array<TypedStatement>, statement:AstStatement):Bool {
		if (output.length == 0)
			return false;
		var previousIsNoReturn = switch output[output.length - 1] {
			case TExpression(expression, _): expression.type == TNever;
			default: false;
		};
		return previousIsNoReturn && switch statement {
			case Return(expression, _):
				switch expression {
					case NullLiteral(_): true;
					default: false;
				}
			case ReturnVoid(_): true;
			default: false;
		};
	}

	function expectedInitializerType(name:String, initializer:AstExpression, statements:Array<AstStatement>, start:Int):Null<CompilerType> {
		if (StringTools.startsWith(name, '$' + 'null-coalesce:'))
			return null;
		switch initializer {
			case NullLiteral(_):
				var assigned = assignedLocalType(name, statements, start);
				if (assigned != null)
					return TNullable(assigned);
			case ArrayLiteral(values, _) if (values.length == 0):
				var element = pushedElementType(name, statements, start);
				if (element != null)
					return TArray(element);
			default:
		}
		var expected = context.localExpectedTypes.get(name);
		if (!usesLocalExpectedType(initializer))
			return session.tolerant ? expected : null;
		return expected != null && containsNullLiteral(initializer) && !isNullable(expected) ? TNullable(expected) : expected;
	}

	function pushedElementType(name:String, statements:Array<AstStatement>, start:Int, ?bindings:Map<String, CompilerType>):Null<CompilerType> {
		var resolvedBindings:Map<String, CompilerType> = bindings == null ? [] : bindings;
		for (index in start...statements.length)
			switch statements[index] {
				case Expression(expression, _):
					var type = pushedElementFromExpression(name, expression, resolvedBindings);
					if (type != null)
						return type;
				case If(_, yes, no, _):
					var type = pushedElementType(name, yes, 0, resolvedBindings);
					if (type == null)
						type = pushedElementType(name, no, 0, resolvedBindings);
					if (type != null)
						return type;
				case While(_, body, _), DoWhile(body, _, _):
					var type = pushedElementType(name, body, 0, resolvedBindings);
					if (type != null)
						return type;
				case ForIn(keyName, valueName, iterable, body, _):
					var loopBindings = copyMap(resolvedBindings);
					switch knownExpressionType(iterable, resolvedBindings) {
						case TArray(element): loopBindings.set(keyName, element);
						case TMap(key, value):
							loopBindings.set(keyName, valueName == null ? value : key);
							if (valueName != null) loopBindings.set(valueName, value);
						case TRange: loopBindings.set(keyName, TInt);
						default:
					}
					var type = pushedElementType(name, body, 0, loopBindings);
					if (type != null)
						return type;
				case Try(tryBranch, catches, _):
					var type = pushedElementType(name, tryBranch, 0, resolvedBindings);
					if (type != null)
						return type;
					for (catchClause in catches) {
						type = pushedElementType(name, catchClause.statements, 0, resolvedBindings);
						if (type != null)
							return type;
					}
				case Switch(_, cases, defaultBranch, _, _):
					for (switchCase in cases) {
						var caseBindings = copyMap(resolvedBindings);
						collectPatternBindingTypes(switchCase.value, caseBindings);
						var type = pushedElementType(name, switchCase.statements, 0, caseBindings);
						if (type != null)
							return type;
					}
					var type = pushedElementType(name, defaultBranch, 0, resolvedBindings);
					if (type != null)
						return type;
				case VarDeclaration(shadowed, _, _, _), UninitializedDeclaration(shadowed, _, _) if (shadowed == name):
					return null;
				default:
			}
		return null;
	}

	function pushedElementFromExpression(name:String, expression:AstExpression, bindings:Map<String, CompilerType>):Null<CompilerType>
		return switch expression {
			case MethodCall(receiverExpression, methodName, arguments, _) if (methodName == "push" && arguments.length == 1):
				switch receiverExpression {
					case Variable(receiver, _) if (receiver == name): knownExpressionType(arguments[0], bindings);
					default: null;
				}
			case Call(callName, arguments, _) if (callName == name + ".push" && arguments.length == 1): knownExpressionType(arguments[0], bindings);
			default: null;
		};

	function collectPatternBindingTypes(pattern:AstExpression, bindings:Map<String, CompilerType>):Void
		switch pattern {
			case Call(name, arguments, _):
				var info = enumCaseInfo(name);
				if (info == null && name.indexOf(".") < 0) {
					var matchedName:Null<String> = null;
					for (enumName => declaration in session.enumDecls)
						for (enumCase in declaration.cases)
							if (enumCase.name == name
								&& arguments.length >= requiredEnumParameters(enumCase.params)
								&& arguments.length <= enumCase.params.length) {
								if (matchedName != null)
									return;
								matchedName = enumName;
							}
					if (matchedName != null)
						info = enumCaseInfo(matchedName + "." + name);
				}
				if (info != null)
					for (index in 0...arguments.length)
						if (index < info.params.length)
							switch arguments[index] {
								case Variable(binding, _) if (binding != "_"):
									bindings.set(binding, session.representation.enumStorageType(info.typeParameters, info.params[index]));
								default:
							}
			default:
		}

	function assignedLocalType(name:String, statements:Array<AstStatement>, start:Int):Null<CompilerType> {
		for (index in start...statements.length)
			switch statements[index] {
				case Assignment(assigned, expression, _) if (assigned == name):
					var type = knownExpressionType(expression);
					if (type != null)
						return type;
				case If(_, yes, no, _):
					var type = assignedLocalType(name, yes, 0);
					if (type == null)
						type = assignedLocalType(name, no, 0);
					if (type != null)
						return type;
				case While(_, body, _), DoWhile(body, _, _), ForIn(_, _, _, body, _):
					var type = assignedLocalType(name, body, 0);
					if (type != null)
						return type;
				case Try(tryBranch, catches, _):
					var type = assignedLocalType(name, tryBranch, 0);
					if (type != null)
						return type;
					for (catchClause in catches) {
						type = assignedLocalType(name, catchClause.statements, 0);
						if (type != null)
							return type;
					}
				case Switch(_, cases, defaultBranch, _, _):
					for (switchCase in cases) {
						var type = assignedLocalType(name, switchCase.statements, 0);
						if (type != null)
							return type;
					}
					var type = assignedLocalType(name, defaultBranch, 0);
					if (type != null)
						return type;
				case VarDeclaration(shadowed, _, _, _), UninitializedDeclaration(shadowed, _, _) if (shadowed == name):
					return null;
				default:
			}
		return null;
	}

	function knownExpressionType(expression:AstExpression, ?bindings:Map<String, CompilerType>):Null<CompilerType>
		return switch expression {
			case Variable(name, _) if (bindings != null): bindings.get(name);
			case Call(name, _, _): knownCallType(name);
			case StringLiteral(_, _): TString;
			case IntegerLiteral(_, _): TInt;
			case FloatLiteral(_, _): TFloat;
			case BoolLiteral(_, _): TBool;
			case ArrayLiteral(values, _) if (values.length > 0): var element = knownExpressionType(values[0], bindings),
					homogeneous = element != null; for (index in 1...values.length) {
					var candidate = knownExpressionType(values[index], bindings);
					if (candidate == null || element == null || !sameType(candidate, element))
						homogeneous = false;
				} homogeneous && element != null ? TArray(element) : null;
			case Range(_, _, _): TRange;
			case New(typeName, _, span):
				if (session.declarations.abstracts.exists(typeName)) session.declarations.resolve(NamedType(typeName),
					span); else session.classDecls.exists(typeName) ? TInstance(NominalKind.Class, typeName, []) : null;
			default: null;
		};

	function contextualExpressionType(expression:AstExpression, scope:Scope):Null<CompilerType> {
		var known = knownExpressionType(expression);
		if (known != null)
			return known;
		return switch expression {
			case Variable(name, _): name.indexOf(".") >= 0 ? typeExpression(expression, scope).type : scope.resolve(name);
			case Member(_, _, _): typeExpression(expression, scope).type;
			case Cast(_, target, _): target == null ? null : lowerType(target);
			default: null;
		};
	}

	function knownCallType(name:String):Null<CompilerType> {
		var signatureName = resolvedCallName(name);
		if (!session.signatures.exists(signatureName))
			return null;
		var signature = requiredMapValue(session.signatures, signatureName);
		return isGeneric(signature) ? null : lowerType(signature.result);
	}

	function resolvedCallName(name:String):String {
		var method = lexicalMethod(name);
		return method == null ? name : method.owner + "." + name;
	}

	function lexicalMethod(name:String):Null<SemanticMethodInfo> {
		if (name.indexOf(".") >= 0 || context.lexicalOwner == null)
			return null;
		return findMethod(context.lexicalOwner, name);
	}

	static function usesLocalExpectedType(initializer:AstExpression):Bool
		return switch initializer {
			case ErrorExpression(_): true;
			case NullLiteral(_): true;
			case ArrayLiteral(values, _): values.length == 0;
			case MapLiteral(entries, _): entries.length == 0;
			case Conditional(_, whenTrue, whenFalse, _): containsNullLiteral(whenTrue) || containsNullLiteral(whenFalse);
			case SwitchExpression(_, _, _, _): true;
			default: false;
		};

	static function containsNullLiteral(expression:AstExpression):Bool
		return ExpressionTyper.containsNullLiteral(expression);

	function inferBodyLocalTypes(statements:Array<AstStatement>, result:CompilerType):Void {
		var changed = true;
		while (changed) {
			changed = inferBodyStatementConstraints(statements, result);
		}
	}

	function inferBodyStatementConstraints(statements:Array<AstStatement>, result:CompilerType):Bool {
		var changed = false;
		for (statement in statements)
			switch statement {
				case VarDeclaration(name, declared, initializer, _):
					if (declared != null)
						changed = constrainLocal(name, lowerType(declared)) || changed;
					if (context.localExpectedTypes.exists(name))
						changed = constrainLocalExpression(initializer, context.localExpectedTypes.get(name)) || changed;
				case Return(expression, _):
					changed = constrainLocalExpression(expression, result) || changed;
				case Assignment(name, expression, _):
					if (session.tolerant) {
						var assigned = knownExpressionType(expression);
						if (assigned != null && !isRecoveryType(assigned))
							changed = constrainLocal(name, assigned) || changed;
					}
				case Expression(expression, _):
					changed = constrainPushedExpression(expression) || changed;
				case If(_, thenBranch, elseBranch, _):
					changed = inferBodyStatementConstraints(thenBranch, result)
						|| inferBodyStatementConstraints(elseBranch, result)
						|| changed;
				case While(_, body, _), DoWhile(body, _, _), ForIn(_, _, _, body, _):
					changed = inferBodyStatementConstraints(body, result) || changed;
				case Try(tryBranch, catches, _):
					changed = inferBodyStatementConstraints(tryBranch, result) || changed;
					for (catchClause in catches)
						changed = inferBodyStatementConstraints(catchClause.statements, result) || changed;
				case Switch(_, cases, defaultBranch, _, _):
					for (switchCase in cases)
						changed = inferBodyStatementConstraints(switchCase.statements, result) || changed;
					changed = inferBodyStatementConstraints(defaultBranch, result) || changed;
				default:
			}
		return changed;
	}

	function constrainPushedExpression(expression:AstExpression):Bool
		return switch expression {
			case MethodCall(receiverExpression, methodName, arguments, _) if (methodName == "push" && arguments.length == 1):
				switch receiverExpression {
					case Variable(receiver, _): constrainPushedValue(receiver, arguments[0]);
					default: false;
				}
			case Call(name, arguments, _) if (arguments.length == 1 && StringTools.endsWith(name, ".push")):
				constrainPushedValue(name.substring(0, name.length - 5), arguments[0]);
			default: false;
		};

	function constrainPushedValue(receiver:String, value:AstExpression):Bool
		return switch context.localExpectedTypes.get(receiver) {
			case TArray(element): constrainLocalExpression(value, element);
			default: false;
		};

	function constrainLocalExpression(expression:AstExpression, expected:CompilerType):Bool
		return switch expression {
			case Variable(name, _): constrainLocal(name, expected);
			case Call(name, arguments, _):
				var info = enumCaseInfo(name);
				var enumName:Null<String> = switch expected {
					case TInstance(Enum, value, _): value;
					case TNullable(element):
						switch element {
							case TInstance(Enum, value, _): value;
							default: null;
						}
					default: null;
				};
				if (info == null && enumName != null && name.indexOf(".") < 0)
					info = enumCaseInfo(enumName + "." + name);
				var changed = false;
				if (info != null)
					for (index in 0...arguments.length) {
						if (index >= info.params.length)
							break;
						var parameter = info.params[index],
							parameterType = session.representation.enumStorageType(info.typeParameters, parameter);
						changed = constrainLocalExpression(arguments[index], parameterType) || changed;
					}
				else {
					var signatureName = resolvedCallName(name);
					if (session.signatures.exists(signatureName)) {
						var signature = requiredMapValue(session.signatures, signatureName);
						if (!isGeneric(signature))
							for (index in 0...arguments.length) {
								if (index >= signature.arguments.length)
									break;
								changed = constrainLocalExpression(arguments[index], argumentType(signature.arguments[index])) || changed;
							}
					}
				}
				changed;
			case ObjectLiteral(fields, _):
				var expectedFields = switch expected {
					case TAnonymous(_, values): values;
					default: null;
				}, changed = false;
				if (expectedFields != null)
					for (field in fields) {
						var expectedField = ExpressionTyper.anonymousField(expectedFields, field.name);
						if (expectedField != null)
							changed = constrainLocalExpression(field.value, expectedField.type) || changed;
					}
				changed;
			default: false;
		};

	function constrainLocal(name:String, expected:CompilerType):Bool {
		if (context.localExpectedTypes.exists(name) || expected == TVoid)
			return false;
		context.localExpectedTypes.set(name, expected);
		return true;
	}

	function typeSwitchArrayPattern(value:AstExpression, expected:CompilerType, scope:Scope):Null<TypedSwitchArrayPattern> {
		return switch value {
			case ArrayLiteral(values, _):
				var elementType = switch expected {
					case TArray(element): element;
					default: return null;
				};
				var elements:Array<TypedSwitchArrayElement> = [];
				for (pattern in values) {
					var isCatchAll = isSwitchCatchAll(pattern),
						subjectBinding = isCatchAll ? null : switchSubjectBinding(pattern, elementType, scope),
						enumPattern = subjectBinding == null && !isCatchAll ? typeEnumPattern(pattern, elementType, scope) : null,
						typedValue:Null<TypedExpression> = null,
						constructorIndex = -1,
						bindings:Array<TypedSwitchBinding> = [],
						predicates:Array<TypedSwitchPredicate> = [];
					if (enumPattern != null) {
						typedValue = enumPattern.value;
						constructorIndex = enumPattern.index;
						bindings = enumPattern.bindings;
						predicates = enumPattern.predicates;
					} else if (subjectBinding == null && !isCatchAll) {
						typedValue = coerce(typeExpression(pattern, scope, elementType), elementType, "array switch pattern", "E1019");
						var literal = enumLiteral(typedValue);
						if (literal != null)
							constructorIndex = literal.index;
					}
					elements.push({
						type: elementType,
						value: typedValue,
						subjectBinding: subjectBinding,
						isCatchAll: isCatchAll,
						constructorIndex: constructorIndex,
						bindings: bindings,
						predicates: predicates
					});
				}
				{elements: elements};
			default: null;
		};
	}

	function switchArrayPatternKey(pattern:TypedSwitchArrayPattern):Null<String> {
		var keys:Array<String> = [];
		for (element in pattern.elements) {
			if (element.isCatchAll || element.subjectBinding != null || element.value == null)
				return null;
			var key = switchCaseKey(element.value, element.predicates);
			if (key == null)
				return null;
			keys.push(key);
		}
		return 'array:${keys.join(",")}';
	}

	function typeEnumPattern(value:AstExpression, expected:CompilerType, scope:Scope):Null<{
		value:TypedExpression,
		enumName:String,
		index:Int,
		bindings:Array<TypedSwitchBinding>,
		predicates:Array<TypedSwitchPredicate>
	}> {
		return switch value {
			case Call(name, arguments, span):
				var info = enumCaseInfo(name);
				if (info == null) {
					var expectedEnum = enumName(expected);
					var constructorName = name.indexOf(".") < 0 ? name : lastPathSegment(name);
					if (expectedEnum != null)
						info = enumCaseInfo(expectedEnum + "." + constructorName);
				}
				if (info == null)
					return null;
				var instanceType = enumInstance(expected) ?? TInstance(NominalKind.Enum, info.enumName, []);
				var instanceName = switch instanceType {
					case TInstance(Enum, value, _): value;
					default: "";
				};
				if (instanceName != info.enumName)
					fail("E1019", "Enum switch case has the wrong enum type", span);
				var required = requiredEnumParameters(info.params);
				if (arguments.length < required || arguments.length > info.params.length)
					fail("E1019", 'Enum switch case "$name" expects $required to ${info.params.length} bindings', span);
				var bindings:Array<TypedSwitchBinding> = [],
					predicates:Array<TypedSwitchPredicate> = [];
				for (index in 0...arguments.length) {
					var parameter = info.params[index],
						parameterType = enumParameterType(info.typeParameters, parameter, instanceType),
						abstractName = enumAbstractPatternName(parameter.type),
						storageType = session.representation.enumStorageType(info.typeParameters, parameter);
					switch arguments[index] {
						case Variable(binding, bindingSpan):
							var constantName = enumAbstractPatternConstant(abstractName, binding);
							if (binding == "_") {} else if (constantName != null
								|| binding.indexOf(".") >= 0
								|| enumLiteralPattern(parameterType, binding)) {
								predicates.push(typeEnumPredicate(arguments[index], parameterType, storageType, index, constantName));
							} else {
								scope.define(binding, parameterType, bindingSpan);
								bindCell(binding, bindingSpan, scope, parameterType);
								bindings.push({
									name: scope.requireId(binding),
									type: parameterType,
									storageType: storageType,
									fieldStorageType: storageType,
									index: index,
									arrayIndex: -1
								});
							}
						case Call(_, _, _):
							var nested = typeEnumPattern(arguments[index], parameterType, scope);
							if (nested == null) {
								predicates.push(typeEnumPredicate(arguments[index], parameterType, storageType, index, null));
							} else {
								predicates.push({
									value: null,
									arrayLength: -1,
									type: parameterType,
									storageType: storageType,
									fieldStorageType: storageType,
									index: index,
									arrayIndex: -1,
									nestedPath: [],
									nestedConstructorIndex: nested.index
								});
								for (predicate in nested.predicates) {
									var nestedPath:Array<TypedSwitchFieldAccess> = [
										{
											constructorIndex: nested.index,
											fieldIndex: predicate.index,
											storageType: predicate.fieldStorageType
										}
									];
									if (predicate.nestedPath != null)
										nestedPath = nestedPath.concat(predicate.nestedPath);
									predicates.push({
										value: predicate.value,
										arrayLength: predicate.arrayLength,
										type: predicate.type,
										storageType: predicate.storageType,
										fieldStorageType: storageType,
										index: index,
										arrayIndex: predicate.arrayIndex,
										nestedPath: nestedPath,
										objectPath: predicate.objectPath,
										nestedConstructorIndex: predicate.nestedConstructorIndex
									});
								}
								for (binding in nested.bindings) {
									var nestedPath:Array<TypedSwitchFieldAccess> = [
										{
											constructorIndex: nested.index,
											fieldIndex: binding.index,
											storageType: binding.fieldStorageType
										}
									];
									if (binding.nestedPath != null)
										nestedPath = nestedPath.concat(binding.nestedPath);
									bindings.push({
										name: binding.name,
										type: binding.type,
										storageType: binding.storageType,
										fieldStorageType: storageType,
										index: index,
										arrayIndex: binding.arrayIndex,
										nestedPath: nestedPath
									});
								}
							}
						case ObjectLiteral(fields, patternSpan):
							switch parameterType {
								case TAnonymous(_, expectedFields):
									for (field in fields) {
										var expectedField = ExpressionTyper.anonymousField(expectedFields, field.name);
										if (expectedField == null)
											fail("E1019", 'Unknown anonymous field "${field.name}" in enum pattern', field.span);
										switch field.value {
											case Variable("_", _):
											default:
												var typed = coerce(typeExpression(field.value, new Scope(), expectedField.type), expectedField.type,
													"enum object payload pattern", "E1019");
												if (constantPatternKey(typed) == null)
													fail("E1019", "Enum object payload patterns must be constants or '_'", patternSpan);
												predicates.push({
													value: typed,
													arrayLength: -1,
													type: expectedField.type,
													storageType: expectedField.type,
													fieldStorageType: storageType,
													index: index,
													arrayIndex: -1,
													objectPath: [
														{
															name: field.name,
															storageType: expectedField.type
														}
													]
												});
										}
									}
								default:
									fail("E1019", "Anonymous object payload patterns require an anonymous value", patternSpan);
							}
						case ArrayLiteral(values, patternSpan):
							switch parameterType {
								case TArray(elementType):
									var elementStorage = switch storageType {
										case TArray(element): element;
										default: elementType;
									};
									predicates.push({
										value: null,
										arrayLength: values.length,
										type: parameterType,
										storageType: storageType,
										fieldStorageType: storageType,
										index: index,
										arrayIndex: -1
									});
									for (arrayIndex in 0...values.length)
										switch values[arrayIndex] {
											case Variable(binding, bindingSpan):
												if (binding != "_") {
													scope.define(binding, elementType, bindingSpan);
													bindCell(binding, bindingSpan, scope, elementType);
													bindings.push({
														name: scope.requireId(binding),
														type: elementType,
														storageType: elementStorage,
														fieldStorageType: storageType,
														index: index,
														arrayIndex: arrayIndex
													});
												}
											default:
												predicates.push(typeEnumPredicate(values[arrayIndex], elementType, elementStorage, index, null, arrayIndex,
													storageType));
										}
								default:
									fail("E1019", "Array payload pattern requires an Array value", patternSpan);
							}
						default:
							predicates.push(typeEnumPredicate(arguments[index], parameterType, storageType, index, null));
					}
				}
				{
					value: new TypedExpression(TEnumLiteral(info.enumName, info.index), instanceType, span),
					enumName: info.enumName,
					index: info.index,
					bindings: bindings,
					predicates: predicates
				};
			default: null;
		};
	}

	function switchSubjectBinding(value:AstExpression, expected:CompilerType, scope:Scope):Null<String> {
		return switch value {
			case Variable(name, span):
				// A qualified name denotes a constant, never a new pattern binding.
				if (name.indexOf(".") >= 0)
					return null;
				var owner = context.lexicalOwner;
				if (owner != null && findStaticFieldNullable(owner, name) != null)
					return null;
				var info = enumCaseInfo(name);
				if (info == null && name.indexOf(".") < 0) {
					var expectedEnum = enumName(expected);
					if (expectedEnum != null)
						info = enumCaseInfo(expectedEnum + "." + name);
				}
				if (info != null) null; else if (name == "_") null; else {
					scope.define(name, expected, span);
					bindCell(name, span, scope, expected);
					scope.requireId(name);
				}
			default: null;
		}
	}

	static function isSwitchCatchAll(value:AstExpression):Bool
		return switch value {
			case Variable(name, _): name == "_";
			default: false;
		};

	function typeEnumPredicate(value:AstExpression, type:CompilerType, storageType:CompilerType, index:Int, constantName:Null<String>, arrayIndex:Int = -1,
			?fieldStorageType:CompilerType):TypedSwitchPredicate {
		switch value {
			case ArrayLiteral(values, span):
				switch type {
					case TArray(_):
						return {
							value: null,
							arrayLength: values.length,
							type: type,
							storageType: storageType,
							fieldStorageType: fieldStorageType == null ? storageType : fieldStorageType,
							index: index,
							arrayIndex: arrayIndex
						};
					default:
						fail("E1019", "Array payload pattern requires an Array value", span);
				}
			default:
		}
		var resolvedValue = switch value {
			case Variable(_, span) if (constantName != null): Variable(Std.string(constantName), span);
			default: value;
		};
		var typed = coerce(typeExpression(resolvedValue, new Scope(), type), type, "enum payload pattern", "E1019");
		if (constantPatternKey(typed) == null)
			fail("E1019", "Enum switch payload patterns must be constants, local names, or '_'", typed.span);
		return {
			value: typed,
			arrayLength: -1,
			type: type,
			storageType: storageType,
			fieldStorageType: fieldStorageType == null ? storageType : fieldStorageType,
			index: index,
			arrayIndex: arrayIndex
		};
	}

	function enumAbstractPatternName(type:AstType):Null<String>
		return switch type {
			case NamedType(name), AppliedType(name, _): session.enumAbstractDecls.exists(name) ? name : null;
			default: null;
		};

	function enumAbstractPatternConstant(abstractName:Null<String>, name:String):Null<String> {
		if (abstractName == null)
			return null;
		var declaration = session.enumAbstractDecls.get(abstractName);
		if (declaration == null)
			return null;
		var memberName = lastPathSegment(name);
		for (value in declaration.values)
			if (value.name == memberName)
				return abstractName + "." + memberName;
		return null;
	}

	function enumLiteralPattern(type:CompilerType, name:String):Bool {
		var expectedEnumName = enumName(type);
		if (expectedEnumName == null || !session.enumDecls.exists(expectedEnumName))
			return false;
		for (enumCase in requiredMapValue(session.enumDecls, expectedEnumName).cases)
			if (enumCase.name == name && enumCase.params.length == 0)
				return true;
		return false;
	}

	function enumPatternKey(name:String, index:Int, predicates:Array<TypedSwitchPredicate>):String {
		if (predicates.length == 0)
			return 'enum:$name:$index';
		var keys = [
			for (predicate in predicates)
				'${predicate.index}:${switchPredicateKey(predicate)}'
		];
		return 'enum:$name:$index:${keys.join(",")}';
	}

	function switchPredicateKey(predicate:TypedSwitchPredicate):String {
		var path = [
			for (access in predicate.nestedPath ?? [])
				'${access.constructorIndex}.${access.fieldIndex}'
		].join("/");
		var objectPath = [for (access in predicate.objectPath ?? []) access.name].join("/");
		if (predicate.nestedConstructorIndex != null)
			return 'enum:${path}:${objectPath}:${predicate.nestedConstructorIndex}';
		if (predicate.arrayLength >= 0)
			return path.length == 0
				&& objectPath.length == 0 ? 'array-length:${predicate.arrayLength}' : 'path:${path}:${objectPath}:array-length:${predicate.arrayLength}';
		var value = predicate.value;
		if (value == null)
			throw "Equality payload predicate has no value";
		return path.length == 0
			&& objectPath.length == 0 ? Std.string(constantPatternKey(value)) : 'path:${path}:${objectPath}:${Std.string(constantPatternKey(value))}';
	}

	function switchCaseKey(value:TypedExpression, predicates:Array<TypedSwitchPredicate>):Null<String>
		return switch value.expression {
			case TIntLiteral(v): 'int:$v';
			case TStringLiteral(v): 'string:$v';
			case TEnumLiteral(name, index): enumPatternKey(name, index, predicates);
			case TNullLiteral: "null";
			case TNullableWrap(inner), TCast(inner), TAbiCast(inner): switchCaseKey(inner, predicates);
			default: null;
		};

	static function enumLiteral(value:TypedExpression):Null<{name:String, index:Int}>
		return switch value.expression {
			case TEnumLiteral(name, index): {name: name, index: index};
			case TNullableWrap(inner), TCast(inner), TAbiCast(inner): enumLiteral(inner);
			default: null;
		};

	function constantPatternKey(value:TypedExpression):Null<String>
		return switch value.expression {
			case TIntLiteral(v): 'int:$v';
			case TBoolLiteral(v): 'bool:$v';
			case TStringLiteral(v): 'string:$v';
			case TEnumLiteral(name, index): 'enum:$name:$index';
			case TNullLiteral: "null";
			case TNullableWrap(inner): constantPatternKey(inner);
			case TCast(inner), TAbiCast(inner): constantPatternKey(inner);
			default: null;
		};

	function typeExpression(expression:AstExpression, scope:Scope, ?expectedType:CompilerType, inferDynamicLambdaResult:Bool = false):TypedExpression {
		session.checkpoint();
		try {
			return expressionTyper.typeExpression(expression, scope, expectedType, inferDynamicLambdaResult);
		} catch (error:CompileError) {
			if (!session.tolerant)
				throw error;
			session.rememberRecoveryDiagnostic(error.diagnostic);
			return new TypedExpression(TNullLiteral, TError, expressionSpan(expression));
		} catch (error:Dynamic) {
			if (Std.isOfType(error, CancellationError) || !session.tolerant)
				throw error;
			rememberRecoveryError(error, expressionSpan(expression));
			return new TypedExpression(TNullLiteral, TError, expressionSpan(expression));
		}
	}

	function typeVariableExpression(name:String, span:SourceSpan, scope:Scope, expectedType:Null<CompilerType>):TypedExpression {
		var type = scope.resolve(name);
		return if (type != null) {
			if (!scope.isAssigned(name))
				fail("E1023", 'Local "$name" may be used before assignment', span);
			new TypedExpression(scope.isCapture(name) ? (scope.isCellCapture(name) ? TCellCaptured(name,
				scope.requireCellClass(name)) : TCaptured(name)) : (boundCell(name,
					scope) != null ? TCellLocal(scope.requireId(name),
						requiredString(boundCell(name, scope))) : TLocal(name == "this" ? name : scope.requireId(name))),
				type, span, false, scope.mapKeySource(name), scope.isCapture(name) ? scope.resolveDeclared(name) : null);
		} else {
			var enumLiteral = expectedEnumLiteral(name, expectedType, span);
			if (enumLiteral != null)
				return enumLiteral;
			var inferredEnumLiteral = uniqueEnumLiteral(name, span);
			if (inferredEnumLiteral != null)
				return inferredEnumLiteral;
			var localMethod = lexicalMethod(name);
			if (localMethod != null && !localMethod.isStatic)
				return typeMember(Variable("this", span), name, span, scope);
			var functionName = localMethod == null ? name : localMethod.owner + "." + name;
			var expectedFunction = expectedFunctionType(expectedType);
			if (name == "Reflect.compare"
				&& expectedFunction != null
				&& expectedFunction.arguments.length == 2
				&& sameType(expectedFunction.arguments[0], TString)
				&& sameType(expectedFunction.arguments[1], TString)
				&& sameType(expectedFunction.result, TInt))
				new TypedExpression(TFunctionRef("__string_compare_full"), TFunction([TString, TString], TInt), span);
			else if (session.signatures.exists(functionName))
				new TypedExpression(TFunctionRef(functionName), functionType(requiredMapValue(session.signatures, functionName)), span);
			else if (session.externals.exists(name)) {
				var external = session.externals.get(name);
				new TypedExpression(TFunctionRef(name), TFunction(external.arguments, external.result), span);
			} else if (session.classDecls.exists(name) || session.enumAbstractDecls.exists(name) || PlatformAbi.isType(name))
				new TypedExpression(TClassRef(name), TInstance(NominalKind.Class, name, []), span);
			else {
				var owner = context.lexicalOwner,
					staticField:Null<{owner:String, type:CompilerType}> = null;
				if (owner != null)
					staticField = findStaticFieldNullable(owner, name);
				if (staticField != null) {
					var inlineValue = inlineStaticFieldExpression(staticField.owner, name, span);
					return inlineValue == null ? new TypedExpression(TStaticField(staticField.owner, name), staticField.type, span) : inlineValue;
				}
				var dot = name.indexOf(".");
				if (dot <= 0) {
					var expectedEnumName = enumName(expectedType);
					if (expectedEnumName != null && session.enumDecls.exists(expectedEnumName)) {
						var expectedEnum = session.enumDecls.get(expectedEnumName);
						for (index in 0...expectedEnum.cases.length) {
							var enumCase = expectedEnum.cases[index];
							if (enumCase.name == name && enumCase.params.length == 0) {
								var literalType:CompilerType = TInstance(NominalKind.Enum, expectedEnum.name, []);
								var resolvedExpected = expectedType;
								if (resolvedExpected != null)
									switch resolvedExpected {
										case TInstance(Enum, _, arguments):
											literalType = TInstance(NominalKind.Enum, expectedEnum.name, arguments);
										case TNullable(element):
											switch element {
												case TInstance(Enum, _, arguments): literalType = TInstance(NominalKind.Enum, expectedEnum.name, arguments);
												default:
											}
										default:
									}
								return new TypedExpression(TEnumLiteral(expectedEnum.name, index), literalType, span);
							}
						}
					}
					var expectedAbstractName = switch expectedType {
						case TAbstract(declaration, _, _): declaration;
						default: null;
					};
					var expectedAbstract = expectedAbstractName == null ? null : session.enumAbstractDecls.get(expectedAbstractName);
					if (expectedAbstract == null && expectedAbstractName != null)
						for (candidateName => candidate in session.enumAbstractDecls)
							if (lastPathSegment(candidateName) == lastPathSegment(expectedAbstractName)) {
								expectedAbstract = candidate;
								break;
							}
					if (expectedAbstract != null) {
						for (value in expectedAbstract.values)
							if (value.name == name)
								return typeExpression(value.value, new Scope(), lowerType(expectedAbstract.underlying));
					}
					var unqualifiedAbstract:Null<compiler.syntax.Ast.AstEnumAbstract> = null;
					for (candidate in session.enumAbstractDecls)
						for (value in candidate.values)
							if (value.name == name) {
								if (unqualifiedAbstract != null)
									fail("E1005", 'Ambiguous enum abstract value "$name"', span);
								unqualifiedAbstract = candidate;
							}
					if (unqualifiedAbstract != null)
						for (value in unqualifiedAbstract.values)
							if (value.name == name)
								return typeExpression(value.value, new Scope(), lowerType(unqualifiedAbstract.underlying));
					var thisType = scope.resolve("this");
					if (thisType == null)
						fail("E1005", 'Unknown variable "$name"', span);
					var field = findFieldType(thisType, name);
					if (field == null)
						fail("E1005", 'Unknown variable "$name"', span);
					typedMemberWithFlow(typeExpression(Variable("this", span), scope), name, span, scope);
				} else {
					var parts = splitPath(name),
						objectName = parts[0],
						fieldName = parts[1],
						enumName = pathBeforeLast(name),
						enumCaseName = lastPathSegment(name);
					if (session.enumAbstractDecls.exists(enumName)) {
						var enumAbstract = session.enumAbstractDecls.get(enumName);
						for (value in enumAbstract.values)
							if (value.name == enumCaseName)
								return typeExpression(value.value, new Scope(), lowerType(enumAbstract.underlying));
					}
					if (session.enumDecls.exists(enumName)) {
						var enumDecl = session.enumDecls.get(enumName);
						var index = -1;
						for (i in 0...enumDecl.cases.length)
							if (enumDecl.cases[i].name == enumCaseName)
								index = i;
						if (index < 0)
							fail("E1005", 'Unknown enum case "$name"', span);
						if (enumDecl.cases[index].params.length > 0)
							fail("E1008", 'Enum case "$name" requires constructor arguments', span);
						var literalType:CompilerType = TInstance(NominalKind.Enum, enumName, []);
						var expectedEnumName = BodyTyper.enumName(expectedType);
						if (expectedEnumName == enumName) {
							var resolvedExpected = expectedType;
							if (resolvedExpected != null)
								switch resolvedExpected {
									case TInstance(Enum, _, arguments):
										literalType = TInstance(NominalKind.Enum, enumName, arguments);
									case TNullable(element):
										switch element {
											case TInstance(Enum, _, arguments): literalType = TInstance(NominalKind.Enum, enumName, arguments);
											default:
										}
									default:
								}
						}
						return new TypedExpression(TEnumLiteral(enumName, index), literalType, span);
					}
					var classEnd = parts.length - 1;
					while (classEnd > 0) {
						var className = parts.slice(0, classEnd).join(".");
						if (session.classDecls.exists(className)
							|| session.enumAbstractDecls.exists(className)
							|| PlatformAbi.isType(className)) {
							var classObject = new TypedExpression(TClassRef(className), TInstance(NominalKind.Class, className, []), span);
							for (index in classEnd...parts.length)
								classObject = typedMember(classObject, parts[index], span);
							return classObject;
						}
						classEnd--;
					}
					var object = typeExpression(Variable(objectName, span), scope);
					for (index in 1...parts.length)
						object = typedMemberWithFlow(object, parts[index], span, scope);
					object;
				}
			}
		};
	}

	function typeBlockExpression(statements:Array<AstStatement>, result:AstExpression, span:SourceSpan, scope:Scope,
			expectedType:Null<CompilerType>):TypedExpression {
		var blockScope = new Scope(scope),
			typedStatements = typeStatements(statements, blockScope, context.expectedReturnType);
		if (ControlFlow.alwaysExits(typedStatements, function(type, cases) return this.exhaustiveEnum(type, cases)))
			return new TypedExpression(TBlockExpression(typedStatements, new TypedExpression(TUnreachable, TNever, span)), TNever, span);
		var typedResult = typeExpression(result, blockScope, expectedType);
		if (expectedType == TVoid && typedResult.type != TVoid && typedResult.type != TNever) {
			typedStatements.push(TExpression(typedResult, typedResult.span));
			typedResult = new TypedExpression(TVoidLiteral, TVoid, typedResult.span);
		}
		// The final expression of a block is an expression branch, not a return
		// statement, so it does not pass through StatementTyper's return coercion.
		// TNull is also used as the provisional result while a switch expression is
		// still inferring its common branch type; defer coercion in that case so a
		// later non-null branch can widen the result to Null<T>.
		if (expectedType != null && expectedType != TNull && expectedType != TVoid && typedResult.type != TNever)
			typedResult = coerce(typedResult, expectedType, "block expression", "E1003");
		if (typedResult.type != TNever) {
			scope.mergeAssignmentsFrom([blockScope]);
			scope.mergeRefinementsFrom([blockScope]);
		}
		return new TypedExpression(TBlockExpression(typedStatements, typedResult), typedResult.type, span);
	}

	function typeMember(object:AstExpression, name:String, span:SourceSpan, scope:Scope):TypedExpression {
		var typedObject = typeExpression(object, scope);
		if (session.tolerant && name.length == 0)
			return typedObject;
		return typedMemberWithFlow(typedObject, name, span, scope);
	}

	function typeGenericCallArguments(fn:AstFunction, arguments:Array<AstExpression>, scope:Scope, span:SourceSpan,
			expectedResult:Null<CompilerType> = null):{
		arguments:Array<TypedExpression>,
		substitutions:Map<String, CompilerType>
	} {
		return callResolver.typeGenericCallArguments(fn, arguments, scope, span, expectedResult);
	}

	function typedMemberWithFlow(object:TypedExpression, name:String, span:SourceSpan, scope:Scope):TypedExpression {
		var objectPath = FlowAnalysis.accessPath(object);
		if (objectPath != null) {
			var refinedObject = scope.resolveExpression(objectPath);
			if (refinedObject != null && !sameType(object.type, refinedObject))
				object = new TypedExpression(TCast(object), refinedObject, object.span);
		}
		var member = typedMember(object, name, span),
			path = FlowAnalysis.accessPath(member);
		if (path == null)
			return member;
		var refined = scope.resolveExpression(path);
		return refined == null
			|| sameType(member.type, refined) ? member : new TypedExpression(TCast(member), refined, member.span, member.stableFlowValue);
	}

	function specializeGeneric(baseName:String, fn:AstFunction, arguments:Array<TypedExpression>, span:SourceSpan, scope:Scope, owner:Null<String>,
			isStatic:Bool, ?presetSubstitutions:Map<String, CompilerType>, ?receiver:TypedExpression):TypedExpression {
		return genericInstantiation.specialize(baseName, fn, arguments, span, scope, owner, isStatic, presetSubstitutions, receiver);
	}

	function inferTypeParameters(pattern:AstType, actual:CompilerType, parameters:Array<String>, substitutions:Map<String, CompilerType>, span:SourceSpan):Void
		return genericInstantiation.inferTypeParameters(pattern, actual, parameters, substitutions, span);

	/** Resolve and memoize an inline field so every use shares its typed value. */
	function resolveInlineConstant(owner:String, name:String, span:SourceSpan):Null<ResolvedInlineConstant>
		return inlineConstantResolver.resolve(owner, name, span);

	function typeInlineInitializer(expression:AstExpression, owner:String, name:String, expected:CompilerType, typeParameters:Array<String>):TypedExpression {
		var body = enterBody(owner + ".__inline", declarationTypeSubstitutions(owner, typeParameters), owner);
		var initializer:TypedExpression;
		try {
			initializer = coerce(typeExpression(expression, new Scope(), expected), expected, 'inline field "$owner.$name"', "E1002");
		} catch (error:Dynamic) {
			leaveBody(body);
			throw error;
		}
		leaveBody(body);
		return initializer;
	}

	/** Resolve an inline static field to its memoized compile-time value. */
	function inlineStaticFieldExpression(owner:String, name:String, span:SourceSpan):Null<TypedExpression> {
		var resolved = resolveInlineConstant(owner, name, span);
		return resolved == null ? null : new TypedExpression(resolved.value.expression, resolved.value.type, span);
	}

	function typedMember(typedObject:TypedExpression, name:String, span:SourceSpan):TypedExpression {
		switch typedObject.type {
			case TUnknown, TError if (session.tolerant):
				// Preserve a member chain after an unresolved receiver. The
				// speculative field has no stable identity, but retaining its
				// shape lets later expressions continue to be typed.
				return new TypedExpression(TField(typedObject, name), TUnknown, span);
			case TNullable(_) if (session.tolerant):
				session.rememberRecoveryDiagnostic(new Diagnostic("E1005", 'Field "$name" requires an object', span));
				return new TypedExpression(TField(typedObject, name), TUnknown, span);
			case TNullable(_):
				fail("E1005", 'Field "$name" requires an object', span);
			default:
		}
		switch typedObject.expression {
			case TClassRef(className):
				if (session.enumAbstractDecls.exists(className)) {
					var abstractDecl = requiredMapValue(session.enumAbstractDecls, className);
					for (value in abstractDecl.values)
						if (value.name == name)
							return typeExpression(value.value, new Scope(), lowerType(abstractDecl.underlying));
				}
				var staticField = findStaticField(className, name, span);
				var inlineValue = inlineStaticFieldExpression(staticField.owner, name, span);
				return inlineValue == null ? new TypedExpression(TStaticField(staticField.owner, name), staticField.type, span) : inlineValue;
			default:
		}
		if (name == "length" && isArray(typedObject.type))
			return new TypedExpression(TArrayLength(typedObject), TInt, span);
		if (name == "length" && sameType(typedObject.type, TString))
			return new TypedExpression(TStringLength(typedObject), TInt, span);
		if (name == "code")
			switch typedObject.expression {
				case TStringLiteral(value) if (value.length == 1):
					return new TypedExpression(TIntLiteral(value.charCodeAt(0)), TInt, span);
				case TStringLiteral(_):
					fail("E1007", "String literal .code requires exactly one character", span);
				default:
			}
		var platformField = PlatformAbi.field(typedObject.type, name);
		if (platformField != null)
			return new TypedExpression(TCall(platformField.get, [typedObject]), platformField.type, span);
		var getter = instancePropertyAccessor(typedObject.type, name, true);
		if (getter != null) {
			var method = requiredMapValue(session.signatures, getter);
			var methodInfo = session.methodInfo.get(getter),
				owner = methodInfo == null ? requiredString(parentPath(getter)) : methodInfo.owner,
				methodResult = session.representation.resolveMethodResult(typedObject.type, owner, method),
				call = new TypedExpression(TMethodCall(typedObject, getter, []), methodResult.physical, span);
			return session.representation.boundaryCast(call, methodResult.semantic);
		}
		var owner = switch typedObject.type {
			case TInstance(Class, className, _), TInstance(Interface, className, _): className;
			default: null;
		};
		if (owner != null) {
			var resolvedMethodInfo = findMethod(owner, name);
			if (resolvedMethodInfo != null && !resolvedMethodInfo.isStatic) {
				var methodKey = resolvedMethodInfo.owner + "." + name,
					method = requiredMapValue(session.signatures, methodKey);
				if (isGeneric(method))
					fail("E1007", "Generic instance method values are not supported yet", span);
				var substitutions = session.representation.nominalSubstitutions(projectNominal(typedObject.type, resolvedMethodInfo.owner)),
					arguments = [for (argument in method.arguments) argumentType(argument, substitutions)],
					result = session.declarations.resolve(method.result, method.span, substitutions);
				return new TypedExpression(TMethodRef(typedObject, methodKey), TFunction(arguments, result), span);
			}
		}
		try {
			var fieldRepresentation = session.representation.resolveField(typedObject.type, name, span),
				stableFlowValue = isStableFlowReceiver(typedObject) && isFinalInstanceField(typedObject.type, name);
			return session.representation.boundaryCast(new TypedExpression(TField(typedObject, name), fieldRepresentation.physical, span, stableFlowValue),
				fieldRepresentation.semantic);
		} catch (error:Dynamic) {
			if (!session.tolerant)
				throw error;
			rememberRecoveryError(error, span);
			return new TypedExpression(TField(typedObject, name), TUnknown, span);
		}
	}

	static function isStableFlowReceiver(value:TypedExpression):Bool
		return switch value.expression {
			case TLocal(_), TCaptured(_): true;
			case TCast(inner), TAbiCast(inner): isStableFlowReceiver(inner);
			case TField(_, _) if (value.stableFlowValue): true;
			default: false;
		};

	function isFinalInstanceField(type:CompilerType, name:String):Bool
		return switch type {
			case TInstance(NominalKind.Class, className, _):
				var declaration = session.classDecls.get(className);
				if (declaration == null) false; else {
					var found = false;
					for (field in declaration.fields)
						if (field.name == name && !field.isStatic) {
							found = true;
							if (field.isFinal)
								return true;
						}
					if (found || declaration.base == null)
						false;
					else
						isFinalInstanceField(session.declarations.resolve(declaration.base, declaration.span,
							session.representation.nominalSubstitutions(type)), name);
				}
			default: false;
		};

	static function unwrapNullable(value:TypedExpression):TypedExpression
		return switch value.type {
			case TNullable(element): new TypedExpression(value.expression, element, value.span);
			default: value;
		};

	function instancePropertyAccessor(type:CompilerType, name:String, read:Bool):Null<String>
		return switch type {
			case TInstance(Class, className, _) if (session.classDecls.exists(className)):
				var declaration = requiredMapValue(session.classDecls, className),
					accessor:Null<String> = null;
				for (field in declaration.fields)
					if (field.name == name && !field.isStatic) {
						var usesAccessor = read ? field.readAccess == GetAccess : field.writeAccess == SetAccess;
						if (usesAccessor)
							accessor = className + "." + (read ? "get_" : "set_") + name;
					}
				if (accessor != null) accessor; else if (declaration.base != null) instancePropertyAccessor(session.declarations.resolve(declaration.base,
					declaration.span, session.representation.nominalSubstitutions(type)), name, read); else null;
			default: null;
		};

	function fieldRepresentationType(type:CompilerType, name:String, span:SourceSpan):CompilerType
		return session.representation.resolveField(type, name, span).physical;

	function findStaticField(className:String, name:String, span:SourceSpan):{owner:String, type:CompilerType} {
		var result = findStaticFieldNullable(className, name);
		if (result != null)
			return result;
		throw new CompileError(new Diagnostic("E1005", 'Unknown static field "$className.$name"', span));
	}

	function findStaticFieldNullable(className:String, name:String):Null<{owner:String, type:CompilerType}> {
		if (!session.classDecls.exists(className))
			return null;
		var classDecl = requiredMapValue(session.classDecls, className);
		for (field in classDecl.fields)
			if (field.name == name && field.isStatic)
				return {owner: className, type: lowerType(session.declarations.resolvedFieldType(className, field))};
		var base = classDecl.base;
		return base == null ? null : findStaticFieldNullable(inheritanceName(base), name);
	}

	function rejectInlineFieldMutation(owner:String, name:String, span:SourceSpan):Void {
		var classDecl = session.classDecls.get(owner);
		if (classDecl == null)
			return;
		for (field in classDecl.fields)
			if (field.isStatic && field.isInline && field.name == name)
				fail("E1002", 'Cannot assign to inline field "$owner.$name"', span);
	}

	function typeMethodCall(object:AstExpression, name:String, arguments:Array<AstExpression>, span:SourceSpan, scope:Scope,
			?expectedType:CompilerType):TypedExpression {
		var receiver = unwrapNullable(typeExpression(object, scope));
		return callResolver.typeMethodCall(receiver, name, arguments, span, scope, expectedType);
	}

	function functionType(fn:AstFunction):CompilerType
		return TFunction([for (argument in fn.arguments) argumentType(argument)], lowerType(fn.result));

	function coerceArguments(arguments:Array<TypedExpression>, expected:Array<CompilerType>, name:String):Array<TypedExpression> {
		return callResolver.coerceArguments(arguments, expected, name);
	}

	function typeCallArguments(arguments:Array<AstExpression>, expected:Array<CompilerType>, scope:Scope, name:String):Array<TypedExpression> {
		return callResolver.typeCallArguments(arguments, expected, scope, name);
	}

	function typeDeclaredCallArguments(arguments:Array<AstExpression>, parameters:Array<compiler.syntax.Ast.AstArgument>, scope:Scope, name:String,
			span:SourceSpan, ?substitutions:Map<String, CompilerType>):Array<TypedExpression> {
		return callResolver.typeDeclaredCallArguments(arguments, parameters, scope, name, span, substitutions);
	}

	function argumentType(argument:compiler.syntax.Ast.AstArgument, ?substitutions:Map<String, CompilerType>):CompilerType {
		var type = if (argument.type == InferredType && argument.defaultValue != null) {
			var inferred = knownExpressionType(argument.defaultValue);
			inferred == null ? TDynamic : inferred;
		} else resolveType(argument.type, substitutions);
		return argument.optional == true && argument.defaultValue == null ? CompilerType.TNullable(type) : type;
	}

	static function isPosInfosParameter(argument:compiler.syntax.Ast.AstArgument):Bool
		return CallResolver.isPosInfosParameter(argument);

	function typeDefaultExpression(expression:AstExpression, expected:CompilerType, declarationName:String):TypedExpression {
		var body = enterBody("$default:" + declarationName, null, parentPath(declarationName));
		try {
			var typed = typeExpression(expression, new Scope(), expected);
			leaveBody(body);
			return typed;
		} catch (error:Dynamic) {
			leaveBody(body);
			throw error;
		}
	}

	function posInfosExpression(span:SourceSpan):AstExpression {
		var owner = parentPath(context.name),
			separator = context.name.lastIndexOf("."),
			method = separator < 0 ? context.name : context.name.substring(separator + 1, context.name.length);
		return ObjectLiteral([
			{name: "fileName", value: StringLiteral(span.file.path, span), span: span},
			{name: "lineNumber", value: IntegerLiteral(span.file.lineAt(span.start), span), span: span},
			{name: "className", value: StringLiteral(owner == null ? "" : owner, span), span: span},
			{name: "methodName", value: StringLiteral(method, span), span: span}
		], span);
	}

	function projectNominal(type:CompilerType, target:String):CompilerType {
		var projected = session.declarations.inheritance.project(type, target);
		return projected == null ? type : projected;
	}

	static function nominalName(type:CompilerType):String
		return switch type {
			case TInstance(_, name, _): name;
			default: "";
		};

	static function inheritanceName(type:AstType):String
		return switch type {
			case NamedType(name), AppliedType(name, _): name;
			default: throw "Inheritance requires a nominal type";
		};

	function coerce(value:TypedExpression, expected:CompilerType, context:String, code:String = "E1009"):TypedExpression {
		return conversionResolver.coerce(value, expected, context, code);
	}

	function isAssignable(actual:CompilerType, expected:CompilerType):Bool {
		return session.relations.isAssignable(actual, expected);
	}

	function findMethod(className:String, name:String):Null<SemanticMethodInfo> {
		return callResolver.findMethod(className, name);
	}

	function enumCaseInfo(name:String):Null<{
		enumName:String,
		index:Int,
		params:Array<compiler.syntax.Ast.AstEnumParameter>,
		typeParameters:Array<String>
	}> {
		var parent = parentPath(name);
		if (parent == null)
			return null;
		var enumName = parent, caseName = lastPathSegment(name);
		if (!session.enumDecls.exists(enumName))
			return null;
		var declaration = requiredMapValue(session.enumDecls, enumName);
		for (index in 0...declaration.cases.length)
			if (declaration.cases[index].name == caseName)
				return {
					enumName: enumName,
					index: index,
					params: declaration.cases[index].params,
					typeParameters: declaration.typeParameters
				};
		return null;
	}

	function enumParameterType(typeParameters:Array<String>, parameter:compiler.syntax.Ast.AstEnumParameter, instance:Null<CompilerType>):CompilerType {
		return session.representation.enumParameterType(typeParameters, parameter, instance);
	}

	function enumStorageParameterType(typeParameters:Array<String>, parameter:compiler.syntax.Ast.AstEnumParameter):CompilerType {
		// A HashLink enum has one physical constructor layout for every source
		// specialization. Erase all payloads of a generic enum so two uses cannot
		// publish incompatible field representations for that shared layout.
		if (typeParameters.length > 0)
			return TDynamic;
		var substitutions:Map<String, CompilerType> = [];
		for (name in typeParameters)
			substitutions.set(name, TDynamic);
		var type = try session.declarations.resolve(parameter.type, parameter.span, substitutions) catch (error:Dynamic) {
			if (!session.tolerant)
				throw error;
			if (Std.isOfType(error, CompileError))
				session.rememberRecoveryDiagnostic((cast error : CompileError).diagnostic);
			TUnknown;
		};
		return parameter.optional ? TNullable(type) : type;
	}
	}

	function erasedEnumParameter(declaration:AstEnum, parameter:compiler.syntax.Ast.AstEnumParameter):CompilerType
		return session.representation.erasedEnumParameter(declaration, parameter);

	static function requiredEnumParameters(parameters:Array<compiler.syntax.Ast.AstEnumParameter>):Int {
		var minimum = 0;
		for (index in 0...parameters.length)
			if (!parameters[index].optional)
				minimum = index + 1;
		return minimum;
	}

	function fieldType(type:CompilerType, name:String, span:SourceSpan):CompilerType
		return session.representation.resolveField(type, name, span).semantic;

	function expectedEnumLiteral(name:String, expectedType:Null<CompilerType>, span:SourceSpan):Null<TypedExpression> {
		var expectedEnumName = enumName(expectedType);
		if (expectedEnumName == null || !session.enumDecls.exists(expectedEnumName))
			return null;
		var declaration = session.enumDecls.get(expectedEnumName),
			caseName = lastPathSegment(name);
		for (index in 0...declaration.cases.length) {
			var enumCase = declaration.cases[index];
			if (enumCase.name == caseName && enumCase.params.length == 0) {
				var literalType:CompilerType = TInstance(NominalKind.Enum, declaration.name, []);
				switch enumInstance(expectedType) {
					case TInstance(Enum, _, arguments):
						literalType = TInstance(NominalKind.Enum, declaration.name, arguments);
					case _:
				}
				return new TypedExpression(TEnumLiteral(declaration.name, index), literalType, span);
			}
		}
		return null;
	}

	function uniqueEnumLiteral(name:String, span:SourceSpan):Null<TypedExpression> {
		var enumName:Null<String> = null, index = -1;
		for (candidateName => declaration in session.enumDecls)
			for (candidateIndex in 0...declaration.cases.length) {
				var enumCase = declaration.cases[candidateIndex];
				if (enumCase.name != name || enumCase.params.length != 0)
					continue;
				if (enumName != null)
					fail("E1005", 'Ambiguous enum value "$name"', span);
				enumName = candidateName;
				index = candidateIndex;
			}
		if (enumName == null)
			return null;
		return new TypedExpression(TEnumLiteral(enumName, index), TInstance(NominalKind.Enum, enumName, []), span);
	}

	function resolveReceiver(name:String, span:SourceSpan, scope:Scope):Null<TypedExpression> {
		if (scope.resolve(name) != null)
			return typeExpression(Variable(name, span), scope);
		var thisType = scope.resolve("this");
		if (thisType != null && findFieldType(thisType, name) != null)
			return typeExpression(Variable(name, span), scope);
		var owner = context.lexicalOwner,
			staticField:Null<{owner:String, type:CompilerType}> = null;
		if (owner != null)
			staticField = findStaticFieldNullable(owner, name);
		if (staticField != null) {
			var inlineValue = inlineStaticFieldExpression(staticField.owner, name, span);
			return inlineValue == null ? new TypedExpression(TStaticField(staticField.owner, name), staticField.type, span) : inlineValue;
		}
		return null;
	}

	function findFieldType(type:CompilerType, name:String):Null<CompilerType>
		return switch type {
			case TAnonymous(_, fields):
				var found:Null<CompilerType> = null;
				for (field in fields)
					if (field.name == name)
						found = field.type;
				found;
			case TInstance(Class, className, arguments):
				var found:Null<CompilerType> = null;
				if (session.classDecls.exists(className)) {
					var classDecl = requiredMapValue(session.classDecls, className);
					for (field in classDecl.fields)
						if (field.name == name && !field.isStatic)
							found = session.declarations.resolve(session.declarations.resolvedFieldType(className, field), field.span,
								session.representation.nominalSubstitutions(type));
					var base = classDecl.base;
					if (found == null && base != null)
						found = findFieldType(session.declarations.resolve(base, classDecl.span, session.representation.nominalSubstitutions(type)), name);
				}
				found;
			default: null;
		};

	function enumCaseCovered(type:CompilerType, constructorIndex:Int, cases:Array<TypedSwitchCoverageCase>):Bool {
		if (!isEnum(type))
			return false;
		for (switchCase in cases)
			if (switchCase.guard == null
				&& (switchCase.isCatchAll
					|| switchCase.subjectBinding != null
					|| switchCase.constructorIndex == constructorIndex
					&& switchCase.predicates.length == 0))
				return true;
		var groups:Map<String, {enumName:String, constructors:Map<Int, Bool>}> = [];
		for (switchCase in cases) {
			if (switchCase.constructorIndex != constructorIndex || switchCase.guard != null || switchCase.predicates.length != 1)
				continue;
			var predicate = switchCase.predicates[0],
				innerIndex = predicate.nestedConstructorIndex;
			if (predicate.arrayLength >= 0 || predicate.arrayIndex >= 0)
				continue;
			if (innerIndex == null) {
				var value = predicate.value;
				if (value == null)
					continue;
				var literal = enumLiteral(value);
				if (literal == null)
					continue;
				innerIndex = literal.index;
			}
			var innerName = enumName(predicate.type);
			if (innerName == null || !session.enumDecls.exists(innerName))
				continue;
			var nestedPath = [
				for (access in predicate.nestedPath ?? [])
					'${access.constructorIndex}.${access.fieldIndex}'
			].join("/"), key = '${predicate.index}:$nestedPath:$innerName', group = groups.get(key);
			if (group == null) {
				group = {enumName: innerName, constructors: []};
				groups.set(key, group);
			}
			group.constructors.set(innerIndex, true);
		}
		for (group in groups)
			if (session.enumDecls.exists(group.enumName)) {
				var declaration = requiredMapValue(session.enumDecls, group.enumName),
					complete = declaration.cases.length > 0;
				for (index in 0...declaration.cases.length)
					if (!group.constructors.exists(index))
						complete = false;
				if (complete)
					return true;
			}
		return false;
	}

	function exhaustiveEnum(type:CompilerType, cases:Array<TypedSwitchCase>):Bool {
		if (isNullableEnum(type))
			return false;
		var enumName = enumName(type);
		if (enumName == null || !session.enumDecls.exists(enumName))
			return false;
		var enumDecl = requiredMapValue(session.enumDecls, enumName),
			coverageCases:Array<TypedSwitchCoverageCase> = [
				for (switchCase in cases)
					{
						constructorIndex: switchCase.constructorIndex,
						subjectBinding: switchCase.subjectBinding,
						isCatchAll: switchCase.isCatchAll,
						guard: switchCase.guard,
						predicates: switchCase.predicates
					}
			];
		for (index in 0...enumDecl.cases.length)
			if (!enumCaseCovered(type, index, coverageCases))
				return false;
		return true;
	}

	function lowerType(type:AstType):CompilerType {
		try {
			return session.representation.semanticType(type, null, context.typeSubstitutions);
		} catch (error:CompileError) {
			if (!session.tolerant)
				throw error;
			session.rememberRecoveryDiagnostic(error.diagnostic);
			return TUnknown;
		}
	}

	function resolveType(type:AstType, ?substitutions:Map<String, CompilerType>):CompilerType {
		try {
			return substitutions == null ? lowerType(type) : session.declarations.resolve(type, null, substitutions);
		} catch (error:CompileError) {
			if (!session.tolerant)
				throw error;
			session.rememberRecoveryDiagnostic(error.diagnostic);
			return TUnknown;
		}
	}

	static function copyMap<T>(source:Map<String, T>):Map<String, T> {
		var result:Map<String, T> = [];
		for (name => value in source)
			result.set(name, value);
		return result;
	}

	static function requiredMapValue<T>(source:Map<String, T>, name:String):T {
		if (!source.exists(name))
			throw 'Missing map entry "$name"';
		return source.get(name);
	}

	static function isGeneric(fn:AstFunction):Bool
		return functionTypeParameters(fn).length > 0;

	static function functionTypeParameters(fn:AstFunction):Array<String> {
		var parameters = fn.typeParameters;
		if (parameters == null)
			return [];
		return parameters;
	}

	function arrayElementType(type:CompilerType, span:SourceSpan):CompilerType
		return switch type {
			case TArray(element): element;
			default:
				fail("E1015", "Indexing requires an Array value", span);
				TVoid;
		};

	function arrayLengthType(type:CompilerType):CompilerType
		return isArray(type) ? TInt : TVoid;

	static function isArray(type:CompilerType):Bool
		return switch type {
			case TArray(_): true;
			default: false;
		};

	static function isIterator(type:CompilerType):Bool
		return switch type {
			case TIterator(_): true;
			default: false;
		};

	static function isMap(type:CompilerType):Bool
		return switch type {
			case TMap(_, _): true;
			default: false;
		};

	static function isEnum(type:CompilerType):Bool
		return switch type {
			case TInstance(Enum, _, _): true;
			case TNullable(inner), TAbstract(_, _, inner): isEnum(inner);
			default: false;
		};

	static function isNullableEnum(type:CompilerType):Bool
		return switch type {
			case TNullable(inner): isEnum(inner);
			default: false;
		};

	static function isNullable(type:CompilerType):Bool
		return switch type {
			case TNullable(_): true;
			default: false;
		};

	static function isReference(type:CompilerType):Bool
		return switch type {
			case TString, TDynamic, TInstance(Class, _, []), TInstance(Interface, _, []), TAnonymous(_, _), TArray(_), TIterator(_), TFunction(_, _),
				TMap(_, _): true;
			default: false;
		};

	static function anonymousField(fields:Null<Array<compiler.types.Type.AnonymousField>>, name:String):Null<compiler.types.Type.AnonymousField> {
		if (fields != null)
			for (field in fields)
				if (field.name == name)
					return field;
		return null;
	}

	function registerAnonymousTypes(type:CompilerType):Void
		anonymousTypeRegistry.register(type);

	static function statementSpan(statement:AstStatement):SourceSpan
		return switch statement {
			case ErrorStatement(span): span;
			case UninitializedDeclaration(_, _, span), VarDeclaration(_, _, _, span), Assignment(_, _, span), IndexAssignment(_, _, _, span),
				FieldAssignment(_, _, _, span), Return(_, span), ReturnVoid(span), Throw(_, span), Try(_, _, span), If(_, _, _, span), While(_, _, span),
				DoWhile(_, _,
					span), ForIn(_, _, _, _, span), Break(span), Continue(span), Switch(_, _, _, _, span), Increment(_, _, span), Expression(_, span): span;
		}

	static function expressionSpan(expression:AstExpression):SourceSpan
		return switch expression {
			case IntegerLiteral(_, span), FloatLiteral(_, span), StringLiteral(_, span), BoolLiteral(_, span), NullLiteral(span), Unreachable(span),
				ErrorExpression(span), Variable(_, span), Member(_, _, span), Add(_, _, span), Sub(_, _, span), Mul(_, _, span), Div(_, _, span),
				Mod(_, _, span), BitAnd(_, _, span), BitXor(_, _, span), BitOr(_, _, span), ShiftLeft(_, _, span), ShiftRight(_, _, span),
				UnsignedShiftRight(_, _, span), Negate(_, span), Less(_, _, span), LessEqual(_, _, span), Greater(_, _, span), GreaterEqual(_, _, span),
				Equal(_, _, span), NotEqual(_, _, span), Not(_, span), Call(_, _, span), ClosureCall(_, _, span), MethodCall(_, _, _, span), New(_, _, span),
				NewGeneric(_, _, _, span), NativeLayoutQuery(_, _, _, span), NewArray(_, _, span), NewMap(_, _, span), Index(_, _, span),
				PostfixIncrement(_, _, span), Lambda(_, _, span), And(_, _, span), Or(_, _, span), Conditional(_, _, _, span), BlockExpression(_, _, span),
				ThrowExpression(_, span), SwitchExpression(_, _, _, span), Cast(_, _, span): span;
			case ObjectLiteral(_, span), ArrayLiteral(_, span), MapLiteral(_, span), ArrayComprehension(_, _, _, _, _, span),
				MapComprehension(_, _, _, _, _, _, span), Range(_, _, span): span;
		}

	static function fail(code:String, message:String, span:SourceSpan):Void
		throw new CompileError(new Diagnostic(code, message, span));

	static function sameType(left:CompilerType, right:CompilerType):Bool
		return TypeRelations.equals(left, right);

	static function isRecoveryType(type:CompilerType):Bool
		return TypeRelations.containsRecovery(type);
}
