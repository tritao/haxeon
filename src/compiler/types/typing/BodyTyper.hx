package compiler.types.typing;

import compiler.core.InternalError;
import compiler.semantic.AbstractStatics;
import compiler.types.typing.MonomorphFrames.MonomorphFrame;

import compiler.types.TypedAst.TypedFunctionRole;
import compiler.syntax.Ast;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstFunction;
import compiler.syntax.Ast.AstStatement;
import compiler.syntax.Ast.AstType;
import compiler.syntax.AstChildren;
import compiler.syntax.AstPredicates;
import compiler.types.FunctionTypes;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;
import compiler.types.Type.AnonymousField;
import compiler.runtime.PlatformAbi;
import compiler.semantic.GenericSpecializationRegistry;
import compiler.types.typing.InlineConstantState.ResolvedInlineConstant;
import compiler.types.typing.CallResolver.EnumConstructorInfo;
import compiler.types.analysis.AssignedDeclarations;
import compiler.types.analysis.BindingWalker;
import compiler.types.analysis.MapEscapeAnalysis;
import compiler.types.analysis.ControlFlow;
import compiler.types.analysis.FlowAnalysis;
import compiler.types.analysis.LexicalStorageAnalysis;
import compiler.types.analysis.Scope;
import compiler.semantic.SemanticProgram.SemanticMethodInfo;
import compiler.semantic.SemanticSignature;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedExpressionKind;
import compiler.types.TypedAst.TypedFunction;
import compiler.types.TypedAst.TypedStatement;
import compiler.types.TypedAst.TypedSwitchBinding;
import compiler.types.TypedAst.TypedSwitchFieldAccess;
import compiler.types.TypedAst.TypedSwitchPredicate;
import compiler.types.TypedAst.TypedSwitchCase;
import compiler.types.TypedAst.TypedSwitchCoverageCase;
import compiler.types.TypedAst.TypedSwitchArrayPattern;
import compiler.types.TypedAst.TypedSwitchArrayElement;
import compiler.core.Diagnostic;
import compiler.core.Diagnostic.CompileError;
import compiler.core.Source.SourceSpan;

/** Types function and expression bodies using the current compilation session. */
@:allow(compiler.types.typing.ProgramTyper)
@:allow(compiler.types.typing.WireCodecGenerator)
@:allow(compiler.types.typing.ValueEqualityGenerator)
@:allow(compiler.types.typing.HashGenerator)
@:allow(compiler.types.typing.DiffIntrinsics)
@:allow(compiler.types.typing.DeclaredConformance)
@:allow(compiler.types.typing.EnumEqualityGenerator)
@:allow(compiler.types.typing.EnumConformanceMethods)
class BodyTyper implements BodyTyping {
	final session:TypingSession;
	final expressionTyper:ExpressionTyper;
	final closureTyper:ClosureTyper;
	final statementTyper:StatementTyper;
	final conversionResolver:ConversionResolver;
	final callResolver:CallResolver;
	public final genericInstantiation:GenericInstantiation;
	final inlineConstantResolver:InlineConstantResolver;
	final anonymousTypeRegistry:AnonymousTypeRegistry;
	var defaultArgumentCaller:Null<String>;
	var context(get, never):TypingContext;

	inline function get_context():TypingContext
		return session.currentContext;

	inline function enterBody(name:String, ?typeSubstitutions:Map<String, CompilerType>, ?ownerOverride:String,
			?sourceFunctionName:String):TypingContext
		return session.enterBody(name, typeSubstitutions, ownerOverride, sourceFunctionName);

	inline function leaveBody(body:TypingContext):Void
		session.leaveBody(body);

	public function new(externals:Null<Map<String, {arguments:Array<CompilerType>, result:CompilerType}>>,
			specializations:Null<GenericSpecializationRegistry>, ?nativeAbiTarget:String) {
		this.session = new TypingSession(externals, specializations, nativeAbiTarget);
		// A `@:to` function is called as the abstract's other instance methods are, in the body being typed.
		this.conversionResolver = new ConversionResolver(session,
			(receiver, method, span) -> callResolver.typeAbstractAccessorCall(receiver, method, [], span,
			context.scope ?? new Scope()));
		session.representation.useConversions(conversionResolver);
		this.inlineConstantResolver = new InlineConstantResolver(session, this);
		this.anonymousTypeRegistry = new AnonymousTypeRegistry(session);
		this.closureTyper = new ClosureTyper(session, this);
		this.genericInstantiation = new GenericInstantiation(session, this);
		this.callResolver = new CallResolver(session, genericInstantiation, this);
		this.expressionTyper = new ExpressionTyper(session, conversionResolver, callResolver, closureTyper,
			anonymousTypeRegistry, this);
		this.statementTyper = new StatementTyper(session, this);
	}

	static function declarationTypeSubstitutions(owner:String, parameters:Array<String>):Map<String, CompilerType> {
		var result:Map<String, CompilerType> = [];
		for (parameter in parameters)
			result.set(parameter, TTypeParameter(owner, parameter));
		return result;
	}

	/** Delegates to the free-standing analysis so the same inference can also run, on plain
	 * canonical signatures, before typing to detect a purity/no-return answer that drifted.
	 */
	function useNoReturnFunctions(known:Map<String, Bool>):Void {
		for (name in known.keys())
			session.noReturnFunctions.set(name, true);
	}

	function declareNoReturnFunctions():Void {
		for (name in compiler.types.analysis.NoReturnDeclarations.declared(session.signatures).keys())
			session.noReturnFunctions.set(name, true);
	}

	/** Every override of a `@:noReturn` method is declared too: a call through the base method must still never return. */
	function checkNoReturnOverrides():Void {
		var violation = compiler.types.analysis.NoReturnDeclarations.undeclaredOverride(session.classDecls,
			session.interfaceDecls);
		if (violation != null)
			fail("E1006",
				'Method ${violation.method.name} overrides or implements @:noReturn ${violation.base} and must be declared @:noReturn too',
				violation.method.span);
	}

	static function hasFunctionMetadata(fn:compiler.syntax.Ast.AstFunction, name:String):Bool {
		if (fn.metadata != null)
			for (entry in fn.metadata)
				if (entry.name == name)
					return true;
		return false;
	}

	static function parentPath(path:String):Null<String> {
		return compiler.core.QualifiedName.parent(path);
	}

	static function pathBeforeLast(path:String):String {
		var parent = parentPath(path);
		return parent == null ? "" : parent;
	}

	static function lastPathSegment(path:String):String {
		return compiler.core.QualifiedName.last(path);
	}

	static function splitPath(path:String):Array<String> {
		return compiler.core.QualifiedName.split(path);
	}

	public static function enumName(type:Null<CompilerType>):Null<String> {
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

	static function requiredExpression(value:Null<TypedExpression>):TypedExpression {
		if (value == null)
			throw new InternalError("Expected typed expression");
		return value;
	}

	static function requiredString(value:Null<String>):String {
		if (value == null)
			throw new InternalError("Expected string");
		return value;
	}

	static function requiredStrings(value:Null<Array<String>>):Array<String> {
		if (value == null)
			throw new InternalError("Expected string array");
		return value;
	}

	static function requiredType(value:Null<CompilerType>):CompilerType {
		if (value == null)
			throw new InternalError("Expected semantic type");
		return value;
	}

	static function requiredFunction(value:Null<AstFunction>):AstFunction {
		if (value == null)
			throw new InternalError("Expected function declaration");
		return value;
	}

	/**
	 * Types `fn`'s body. With `inference`, `fn` is an unannotated function whose signature its body gives it
	 * (docs/design/LAZY_DECLARATION_TYPING.md): each unannotated argument without a default and an unannotated result are type
	 * variables of the body's own frame, which a read of the function from its own body gets too (`FunctionInference.provisional`);
	 * the body fixes them, and they are final when the frame is settled (`FunctionInference.settle`).
	 */
	public function typeFunction(fn:AstFunction, ?owner:String, isStatic:Bool = false,
			?substitutions:Map<String, CompilerType>, ?specializedName:String,
			?abstractReceiver:CompilerType, ?physicalOwner:String,
			?ownerTypeArguments:Array<CompilerType>,
			?inference:DeclarationTypeTable.FunctionInference, ?elaboration:GenericElaboration):TypedFunction {
		compiler.types.analysis.ScopedEscapeChecker.check(fn.arguments, fn.statements);
		var elaborationMark = elaboration == null ? null : session.closureConversion.mark();
		var functionName = specializedName == null
			? (owner == null ? fn.name : owner + "." + fn.name) : specializedName;
		// The declaration the query knows: the prologue below makes a copy of it.
		var declaration = fn;
		var functionContext:Null<TypingContext> = null, frame:Null<MonomorphFrame> = null;
		if (inference != null) {
			// The body's frame holds the signature's type variables, so it is begun before anything reads the signature.
			functionContext = enterBody(functionName, substitutions, null, null);
			frame = session.monomorphs.begin(session.closureConversion.mark());
			frame.declaration = functionName;
			inference.provisional(provisionalSignature(declaration, functionName, substitutions));
		}
		var argumentTypes = argumentTypesOf(declaration, substitutions);
		for (index in 0...fn.arguments.length) {
			var argumentValueType = argumentTypes[index];
			if (compiler.ffi.NativeLayout.containsUnsupportedRuntimeValueType(argumentValueType))
				fail("E1022",
					'Native layout type "$argumentValueType" cannot be passed or stored as a Haxe runtime value yet',
					fn.arguments[index].span);
		}
		var result = substitutions == null ? functionResultType(declaration,
			fn.span) : session.declarations.types.resultType(declaration, substitutions);
		fn = DefaultArguments.withFunctionPrologue(fn, argumentTypes, session.relations);
		if (compiler.ffi.NativeLayout.containsUnsupportedRuntimeValueType(result))
			fail("E1022", 'Native layout type "$result" cannot be returned as a Haxe runtime value yet', fn.span);
		if (functionContext == null)
			functionContext = enterBody(functionName, substitutions, specializedName == null ? null : owner,
				specializedName == null ? null : owner == null ? fn.name : owner + "." + fn.name);
		var lexicalStorage = LexicalStorageAnalysis.analyze(fn.statements, fn.arguments, session.mayHoldValue,
			session.mayBeKeyPath);
		for (binding in lexicalStorage.closureWrites.keys())
			context.storage.closureWrites.set(binding, true);
		for (declaration in AssignedDeclarations.ofFunction(fn.arguments, fn.statements).declarations.keys())
			context.assignedDeclarations.set(declaration, true);
		for (binding in lexicalStorage.mutableCaptures.keys()) {
			context.storage.request(binding, '$' + 'cell:' + context.name + ':' + BindingWalker.nameOf(binding),
				MutableCapture);
		}
		for (binding in lexicalStorage.exceptionCells.keys()) {
			context.storage.request(binding, '$' + 'cell:' + context.name + ':' + BindingWalker.nameOf(binding),
				ExceptionEdge);
		}
		var scope = new Scope();
		scope.setMapPrivacy(MapEscapeAnalysis.analyze(fn.arguments, fn.statements));
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
		// Resolved again inside the body: with no substitutions given, the body's own context supplies them.
		var bodyArgumentTypes = argumentTypesOf(declaration, substitutions);
		for (index in 0...fn.arguments.length) {
			var argument = fn.arguments[index], type = bodyArgumentTypes[index];
			scope.define(argument.name, type, argument.span);
			var constants = session.keyPaths.parameters.get(functionName);
			if (constants != null && constants.exists(argument.name)) {
				scope.setKeyPathConstant(argument.name, constants.get(argument.name));
				continue;
			}
			bindCell(argument.name, argument.span, scope, type);
			arguments.push({name: scope.requireId(argument.name), type: type});
		}
		context.expectedReturnType = result;
		var monomorphs = frame == null ? session.monomorphs.begin(session.closureConversion.mark()) : frame;
		var typedStatements = typeStatements(fn.statements, scope, result);
		if (inference != null) {
			closeSignature(declaration, functionName, argumentTypes, result);
			var map = settleFrame(monomorphs);
			if (map != null) {
				typedStatements = map.statements(typedStatements);
				arguments = [for (argument in arguments) {
					name:argument.name, type:map.type(argument.type)
				}];
			}
			result = session.monomorphs.settled(result);
			var signature = settledSignature(declaration, argumentTypes, result);
			for (argument in signature.arguments)
				if (argument != null)
					session.monomorphs.recordDeclarationType(monomorphs, argument);
			if (signature.result != null)
				session.monomorphs.recordDeclarationType(monomorphs, signature.result);
			inference.settle(signature);
			for (index in 0...arguments.length)
				if (compiler.ffi.NativeLayout.containsUnsupportedRuntimeValueType(arguments[index].type))
					fail("E1022",
						'Native layout type "${arguments[index].type}" cannot be passed or stored as a Haxe runtime value yet',
						fn.span);
			if (compiler.ffi.NativeLayout.containsUnsupportedRuntimeValueType(result))
				fail("E1022", 'Native layout type "$result" cannot be returned as a Haxe runtime value yet', fn.span);
		}
		var statements = inference == null ? settleMonomorphs(monomorphs, typedStatements) : typedStatements;
		if (compiler.types.analysis.NoReturnDeclarations.has(fn)) {
			if (compiler.types.analysis.AstScan.returns(fn.statements))
				fail("E1006", 'Function ${fn.name} is declared @:noReturn but returns', fn.span);
			if (!ControlFlow.alwaysExits(statements, function(type, cases) return this.exhaustiveSwitch(type, cases)))
				fail("E1006", 'Function ${fn.name} is declared @:noReturn but can finish without throwing', fn.span);
		}
		if ((switch (result) {
			case TVoid: false;
			default: true;
		}) && !ControlFlow.returnsOnEveryPath(statements,
			function(type, cases) return this.exhaustiveSwitch(type, cases)))
			fail("E1006", 'Function ${fn.name} does not return on every path', fn.span);
		// Typed with its own type parameters, the body is made into the code of the representation asked for, in its context.
		if (elaboration != null) {
			statements = elaboration.statements(statements);
			arguments = [for (argument in arguments) {
				name:argument.name, type:elaboration.type(argument.type)
			}];
			result = elaboration.type(result);
			if (elaborationMark != null)
				session.closureConversion.mapTypesSince(elaborationMark, elaboration);
		}
		var typeArguments:Null<Array<CompilerType>> = ownerTypeArguments,
			typeParameters = fn.typeParameters;
		if (specializedName != null && typeParameters != null) {
			var resolvedArguments:Array<CompilerType> = [];
			for (parameter in typeParameters) {
				if (!context.typeSubstitutions.exists(parameter))
					throw new InternalError('Missing specialization for type parameter "$parameter"');
				resolvedArguments.push(context.typeSubstitutions.get(parameter));
			}
			typeArguments = resolvedArguments;
		}
		var resultFunction:TypedFunction = {
			name: functionName,
			role: specializedName == null ? UserFunction : GenericFunction,
			origin: specializedName == null ? null : (owner == null ? fn.name : owner + "." + fn.name),
			originKind: specializedName == null ? null : compiler.types.TypedAst.FunctionOriginKind.Specialization,
			typeArguments: typeArguments,
			owner: owner,
			physicalOwner: physicalOwner,
			isStatic: isStatic,
			isConstructor: isConstructor,
			isInline: fn.isInline == true,
			isKept: hasFunctionMetadata(fn, "keep"),
			isExposed: hasFunctionMetadata(fn, "expose"),
			arguments: arguments,
			result: result,
			dispatchEntry: !isConstructor && abstractReceiver == null && arguments.length == fn.arguments.length
				&& DefaultArguments.hasDispatchEntry(fn.arguments, [for (argument in arguments) argument.type],
				session.relations) ? DefaultArguments.dispatchName(functionName) : null,
			statements: statements,
			cells: copyMap(context.storage.cells),
			cellCaptures: [],
			span: fn.span,
			warnings: functionContext.warnings.copy()
		};
		for (name in context.storage.cells.keys()) {
			if (context.storage.types.exists(name) && context.storage.kinds.exists(name))
				session.closureConversion.addCell(requiredMapValue(context.storage.cells, name),
					elaborated(elaboration, session.monomorphs.settled(requiredMapValue(context.storage.types, name))),
					requiredMapValue(context.storage.kinds, name));
		}
		if (resultFunction.dispatchEntry != null) {
			var entry = dispatchEntry(resultFunction, fn, physicalOwner == null ? owner : physicalOwner, substitutions);
			session.closureConversion.addFunction(elaboration == null ? entry : elaboration.typedFunction(entry));
		}
		leaveBody(functionContext);
		return resultFunction;
	}

	/** `value` crossing to `target`, of substituted types, as `TypeRepresentation.boundaryCast` makes it (`GenericElaboration`). */
	public function elaborateBoundary(value:TypedExpression, target:CompilerType):TypedExpression
		return session.representation.boundaryCast(value, target);

	/** `operation` on `arguments`, of substituted types, with the helper the types ask for (`GenericElaboration`). */
	public function elaborateOperation(operation:compiler.types.TypedAst.ParameterOperation,
			arguments:Array<TypedExpression>,
			span:SourceSpan):TypedExpression
		return switch operation {
			case Equality(name): callResolver.equalityCall(name, arguments[0], arguments[1], span);
			case ArraySearch(name): callResolver.arraySearch(name, arguments[0], arguments[1], span, true);
		};

	static function elaborated(elaboration:Null<GenericElaboration>, type:CompilerType):CompilerType
		return elaboration == null ? type : elaboration.type(type);

	/**
	 * The signature a read of the unannotated function `fn` gets while its body is typed: a type variable for each unannotated
	 * argument without a default (nullable when the argument is optional) and for an unannotated result, made in the body's own
	 * frame; an unannotated argument with a default has the default's type.
	 */
	function provisionalSignature(fn:AstFunction, name:String,
			substitutions:Null<Map<String, CompilerType>>):compiler.types.DeclarationTypes.InferredSignature {
		var arguments:Array<Null<CompilerType>> = [];
		for (argument in fn.arguments)
			if (!compiler.syntax.AstFunctions.isInferred(argument.type))
				arguments.push(null);
			else if (argument.defaultValue != null)
				arguments.push(session.declarations.declaredTypes.argumentType(argument, substitutions,
					defaultValueType(argument.defaultValue)));
			else {
				var variable = requiredType(session.monomorphs.create(argumentOrigin(argument.name, name),
					argument.span));
				arguments.push(AstPredicates.isNullableArgument(argument) ? TNullable(variable) : variable);
			}
		return {
			arguments: arguments,
			result: compiler.syntax.AstFunctions.isInferred(fn.result)
				? requiredType(session.monomorphs.create('the return type of function "$name"',
				fn.span)) : null
		};
	}

	/**
	 * Closes the signature of the unannotated function `fn` once its body is typed, before its frame is settled: a result no value
	 * return fixed is Void, as in Haxe, and a type variable of the signature that nothing in the body fixed is an error asking for an
	 * annotation, since only a caller, in another unit, could fix it (docs/design/LAZY_DECLARATION_TYPING.md, decision 1).
	 */
	function closeSignature(fn:AstFunction, name:String, argumentTypes:Array<CompilerType>, result:CompilerType):Void {
		if (compiler.syntax.AstFunctions.isInferred(fn.result)) {
			if (compiler.types.Monomorphs.isUnbound(result))
				compiler.types.Monomorphs.close(result, TVoid);
			var unfixed = compiler.types.Monomorphs.firstUnfixed(result);
			if (unfixed != null)
				fail("E1002",
					'Cannot infer the return type of function "$name": nothing in its body fixes ${unfixed.origin}; annotate it',
					fn.span);
		}
		for (index in 0...fn.arguments.length) {
			var argument = fn.arguments[index];
			if (!compiler.syntax.AstFunctions.isInferred(argument.type) || argument.defaultValue != null)
				continue;
			var unfixed = compiler.types.Monomorphs.firstUnfixed(argumentTypes[index]);
			if (unfixed != null)
				fail("E1002",
					'Cannot infer the type of argument "${argument.name}" of function "$name": nothing in its body fixes '
					+ (unfixed.origin == argumentOrigin(argument.name, name) ? "it" : unfixed.origin) + "; annotate it",
					argument.span);
		}
	}

	static function argumentOrigin(argument:String, functionName:String):String
		return 'the type of argument "$argument" of function "$functionName"';

	/** The settled signature of the unannotated function `fn`: its unannotated parts, with their type variables replaced. */
	function settledSignature(fn:AstFunction, argumentTypes:Array<CompilerType>,
			result:CompilerType):compiler.types.DeclarationTypes.InferredSignature
		return {
			arguments: [
				for (index in 0...fn.arguments.length)
					compiler.syntax.AstFunctions.isInferred(fn.arguments[index].type)
					? session.monomorphs.settled(argumentTypes[index]) : null
			],
			result: compiler.syntax.AstFunctions.isInferred(fn.result)
				? session.monomorphs.settled(result) : null
		};

	/**
	 * The dispatch entry of `body`, typed from `fn`, when it has one (`DefaultArguments`): it takes `Null<T>` for each
	 * argument with a value default, replaces null with the default and calls `body`. Its defaults are typed here, once,
	 * in the function's own unit.
	 */
	function dispatchEntry(body:TypedFunction, fn:AstFunction, receiverOwner:Null<String>,
			substitutions:Null<Map<String, CompilerType>>):TypedFunction {
		var span = fn.span,
			arguments:Array<{name:String, type:CompilerType}> = [],
			callArguments:Array<TypedExpression> = [];
		if (!body.isStatic && receiverOwner != null) {
			// A generic owner's shared body takes its receiver as the erased class, as its method slot does.
			var declaration = session.classDecls.get(requiredString(body.owner));
			callArguments.push(new TypedExpression(TLocal("this"),
				declaration != null && declaration.typeParameters.length > 0 ? TInstance(NominalKind.Class,
				receiverOwner, []) : session.representation.receiverType(requiredString(body.owner),
				context.typeSubstitutions), span));
		}
		for (index in 0...fn.arguments.length) {
			var argument = fn.arguments[index], parameter = body.arguments[index];
			if (!DefaultArguments.valueDefault(argument, parameter.type, session.relations)) {
				arguments.push(parameter);
				callArguments.push(new TypedExpression(TLocal(parameter.name), parameter.type, argument.span));
				continue;
			}
			var boxedType = CompilerType.TNullable(parameter.type),
				boxed = new TypedExpression(TLocal(parameter.name), boxedType, argument.span),
				absent = new TypedExpression(TEqual(boxed,
					new TypedExpression(TNullableWrap(new TypedExpression(TNullLiteral, TNull, argument.span)),
					boxedType,
					argument.span)),
					TBool, argument.span),
				defaultValue = coerce(typeDefaultExpression(argument.defaultValue, parameter.type, body.name),
					parameter.type, 'default argument ${index + 1} to "${body.name}"');
			arguments.push({name: parameter.name, type: boxedType});
			callArguments.push(new TypedExpression(TConditional(absent, defaultValue,
				new TypedExpression(TCast(boxed), parameter.type, argument.span)), parameter.type, argument.span));
		}
		var call = new TypedExpression(TCall(body.name, callArguments), body.result, span);
		return {name: requiredString(body.dispatchEntry),
			role: OtherFunction,
			origin: body.name,
			originKind: compiler.types.TypedAst.FunctionOriginKind.Helper,
			typeArguments: body.typeArguments,
			owner: body.owner,
			physicalOwner: body.physicalOwner,
			isStatic: body.isStatic,
			isConstructor: false,
			arguments: arguments,
			result: body.result,
			statements: switch body.result {
				case TVoid: [TExpression(call, span), TReturnVoid(span)];
				default: [TReturn(call, span)];
			},
				cells: [],
				cellCaptures: [],
				span: span};
	}

	/**
	 * Ends a body's type variables (`Monomorphs`): one nothing filled is Dynamic (or an error, for a `new Map()`), and every
	 * one is replaced by its type in the body's statements, its lambdas and their cache entries, and its closure cells, so none leaves the typer.
	 */
	function settleMonomorphs(frame:MonomorphFrame, statements:Array<TypedStatement>):Array<TypedStatement> {
		var map = settleFrame(frame);
		return map == null ? statements : map.statements(statements);
	}

	/**
	 * A field initializer, typed as a body is: in a type-variable frame of its own, so an empty `[]`, `new Map()` or `null` inside it
	 * (in a comprehension, a nested literal, a lambda's locals) is settled by what follows it there, as in a function body.
	 */
	public function typeFieldInitializer(expression:AstExpression, scope:Scope, type:CompilerType,
			label:String):TypedExpression {
		var frame = session.monomorphs.begin(session.closureConversion.mark()), typed:TypedExpression;
		try
			typed = coerce(typeExpression(expression, scope, type), type, label, "E1002")
		catch (error:haxe.Exception) {
			session.monomorphs.discard(frame);
			throw error;
		}
		var map = settleFrame(frame);
		return map == null ? typed : map.expression(typed);
	}

	/**
	 * The initializer of the unannotated field `name` of `owner`, whose type is the field's (docs/design/LAZY_DECLARATION_TYPING.md).
	 * It is typed in a frame of its own, and the field's type is final when the frame is settled: a type variable of that type that
	 * nothing in the initializer fixes (`[]`, `new Map()`, a lone `null`) is an error asking for an annotation, since only a later
	 * use, in another unit, could fix it. While it is typed, a read of the field itself gets `provisional`'s argument, a type
	 * variable of this frame that the initializer's type then fills, as a self-reference reads its own field in Haxe.
	 */
	public function typeInferredFieldInitializer(expression:AstExpression, scope:Scope, owner:String, name:String,
			isStatic:Bool, span:SourceSpan, provisional:CompilerType->Void):TypedExpression {
		var frame = session.monomorphs.begin(session.closureConversion.mark()),
			field = 'field "$owner.$name"',
			typed:TypedExpression;
		frame.declaration = '$owner.$name';
		frame.declarationIsField = true;
		try {
			var self = requiredType(session.monomorphs.create('the type of $field', span));
			provisional(self);
			var value = typeExpression(expression, scope, null);
			if (TypeRelations.equals(value.type, TNull))
				fail("E1002",
					'Cannot infer the type of $field: nothing in its initializer fixes the type of its null value; annotate it',
					span);
			compiler.types.Monomorphs.unify(self, value.type);
			var unfixed = compiler.types.Monomorphs.firstUnfixed(value.type);
			if (unfixed != null)
				fail("E1002",
					'Cannot infer the type of $field: nothing in its initializer fixes ${unfixed.origin}; annotate it',
					span);
			typed = coerce(value, value.type, isStatic ? 'static $field' : field, "E1002");
		} catch (error:haxe.Exception) {
			session.monomorphs.discard(frame);
			throw error;
		}
		var map = settleFrame(frame), settled = map == null ? typed : map.expression(typed);
		session.monomorphs.recordDeclarationType(frame, settled.type);
		return settled;
	}

	/**
	 * Ends `frame` and settles its type variables: an unbound one is Dynamic, as in Haxe, except a `new Map()`'s key and value,
	 * which are an error (`MonomorphCell.mustBeFixed`); then closes its literals' structures. Returns the map that writes the
	 * settled types into what was typed in the frame (closure conversions and lambdas are mapped here), or null when the frame
	 * made neither.
	 */
	function settleFrame(frame:MonomorphFrame):Null<compiler.types.TypedTypeMap> {
		session.monomorphs.end(frame);
		if (frame.cells.length == 0 && frame.literals.length == 0)
			return null;
		var unfixed:Null<compiler.types.Type.MonomorphCell> = null;
		for (cell in frame.cells) {
			if (!compiler.types.Monomorphs.isUnbound(TMonomorph(cell)))
				continue;
			// Otherwise it is Dynamic, as an unbound monomorph is in Haxe, which says nothing of it. Every one is settled before an
			// error is reported, so that none is left open after the body fails.
			if (cell.mustBeFixed && unfixed == null)
				unfixed = cell;
			var localName = cell.localName, localSpan = cell.localSpan;
			if (localName != null && localSpan != null && !cell.mustBeFixed)
				session.output.records.unboundLocals.push({name: localName, span: localSpan, what: cell.origin});
			compiler.types.Monomorphs.unify(TMonomorph(cell), TDynamic);
		}
		// The literals' structures close once their fields' type variables are settled: each is named after its final fields.
		session.monomorphs.closeFrame(frame);
		if (unfixed != null)
			fail("E1003", 'Cannot infer ${unfixed.origin}: nothing after it fixes it; give it a type', unfixed.span);
		for (check in frame.deferred)
			check();
		var map = new compiler.types.TypedTypeMap(frame.literals.length == 0
			? compiler.types.Monomorphs.resolve : session.monomorphs.settled);
		session.closureConversion.mapTypesSince(frame.conversionMark, map);
		for (key in frame.lambdaKeys)
			session.mapCachedLambda(key, map);
		return map;
	}

	public function boundCell(name:String, scope:Scope):Null<String> {
		var id = scope.resolveId(name);
		return id == null ? null : context.storage.cell(id);
	}

	public function bindCell(name:String, span:SourceSpan, scope:Scope, type:CompilerType):Void {
		var id = scope.requireId(name),
			declaration = LexicalStorageAnalysis.key(name, span);
		// Refine conservative receiver writes once their type is known. Whole assignments keep their storage and flow effects.
		if (context.storage.candidateKind(declaration) == MutableCapture
			&& !context.assignedDeclarations.exists(declaration)) {
			if (referenceCapture(type)) {
				context.storage.closureWrites.remove(declaration);
				return;
			}
			if (valueCapture(type))
				context.storage.closureWrites.remove(declaration);
		}
		context.storage.bind(declaration, id, type);
	}

	function referenceCapture(type:CompilerType):Bool
		return switch type {
			case TNullable(element): referenceCapture(element);
			case TInstance(NominalKind.Class, name, _): session.classDecls.exists(name)
				&& !session.relations.isValueClass(type);
			case TFunction(_, _, _), TAbstract(_, _, _), TDynamic, TNativeAbstract(_): false;
			default: compiler.types.TypeRelations.isReference(type);
		};

	function valueCapture(type:CompilerType):Bool
		return switch type {
			case TNullable(element): valueCapture(element);
			default: session.relations.isValueClass(type);
		};

	/** A cleanup cannot replace a pending exit with a transfer out of its own body. */
	function validateDeferredControl(statements:Array<AstStatement>, loopDepth:Int):Void {
		for (statement in statements) {
			for (expression in AstChildren.statementExpressions(statement))
				validateDeferredExpression(expression, loopDepth);
			switch statement {
				case PrivateAccessStatement(inner, _):
					validateDeferredControl([inner], loopDepth);
				case Return(_, span), ReturnVoid(span):
					fail("E1019", "Cannot return from a deferred statement", span);
				case Break(span), Continue(span) if (loopDepth == 0):
					fail("E1019", "Cannot leave a deferred statement with break or continue", span);
				case If(_, yes, no, _):
					validateDeferredControl(yes, loopDepth);
					validateDeferredControl(no, loopDepth);
				case While(_, body, _), DoWhile(body, _, _), ForIn(_, _, _, body, _):
					validateDeferredControl(body, loopDepth + 1);
				case Try(body, catches, _):
					validateDeferredControl(body, loopDepth);
					for (handler in catches)
						validateDeferredControl(handler.statements, loopDepth);
				case Switch(_, cases, fallback, _, _):
					for (arm in cases)
						validateDeferredControl(arm.statements, loopDepth);
					validateDeferredControl(fallback, loopDepth);
				case Defer(body, _):
					validateDeferredControl(body, 0);
				default:
			}
		}
	}

	function validateDeferredExpression(expression:AstExpression, loopDepth:Int):Void {
		switch expression {
			// A lambda has its own return and loop targets; its body is checked when it is typed.
			case Lambda(_, _, _, _):
				return;
			case BlockExpression(statements, result, _):
				validateDeferredControl(statements, loopDepth);
				validateDeferredExpression(result, loopDepth);
				return;
			default:
		}
		for (child in AstChildren.expressions(expression))
			validateDeferredExpression(child, loopDepth);
	}

	public function typeStatements(statements:Array<AstStatement>, scope:Scope,
			result:Null<CompilerType>):Array<TypedStatement> {
		var output:Array<TypedStatement> = [];
		for (statementIndex in 0...statements.length) {
			var statement = statements[statementIndex];
			if (ControlFlow.alwaysReturns(output, function(type, cases) return this.exhaustiveSwitch(type, cases))) {
				if (isNoReturnPlaceholder(output, statement))
					continue;
				fail("E1012", "Unreachable statement", statementSpan(statement));
			}
			var simpleStatement = statementTyper.typeSimpleStatement(statement, scope, result, statements,
				statementIndex);
			if (simpleStatement != null) {
				for (typedStatement in simpleStatement)
					output.push(typedStatement);
				continue;
			}
			switch statement {
				case PrivateAccessStatement(inner, _):
					session.currentContext.privateAccessDepth++;
					try {
						for (typed in typeStatements([inner], scope, result))
							output.push(typed);
					} catch (error:haxe.Exception) {
						session.currentContext.privateAccessDepth--;
						throw error;
					}
					session.currentContext.privateAccessDepth--;
				case ErrorStatement(_):
					throw new InternalError("Simple statement was not dispatched");
				case UninitializedDeclaration(_, _, _):
					throw new InternalError("Simple statement was not dispatched");
				case VarDeclaration(_, _, _, _):
					throw new InternalError("Simple statement was not dispatched");
				case ScopedDeclaration(name, declared, initializer, span):
					var declaration = VarDeclaration(name, declared, initializer, span);
					var typed = statementTyper.typeSimpleStatement(declaration, scope, result, statements,
						statementIndex);
					if (typed == null)
						throw new InternalError("Scoped declaration was not typed");
					for (item in typed)
						output.push(item);
					var boundType = scope.resolveDeclared(name);
					if (boundType == null)
						throw new InternalError("Scoped binding was not declared");
					// A no-return initializer never registers cleanup and has no value to dispatch on.
					if ((switch boundType {
						case TNever: true;
						default: false;
					}))
						continue;
					var element = switch boundType {
						case TNullable(inner): inner;
						default: boundType;
					};
					var contract = lowerType(NamedType("Disposable"), span);
					if (!satisfiesDisposable(element, contract))
						fail("E1002", 'Scoped binding "$name" requires Disposable conformance', span);
					scope.markScoped(name);
					context.scopedBindings.set(scope.requireId(name), name);
					var call = Expression(MethodCall(Variable(name, span), "dispose", [], span), span);
					var cleanup:Array<AstStatement> = switch boundType {
						case TNullable(_): [If(NotEqual(Variable(name, span), NullLiteral(span), span), [call], [],
							span)];
						default: [call];
					};
					output.push(TDefer(typeStatements(cleanup, new Scope(scope), result), span, true));
				case Return(expression, span):
					throw new InternalError("Simple statement was not dispatched");
				case ReturnVoid(span):
					throw new InternalError("Simple statement was not dispatched");
				case Throw(expression, span):
					throw new InternalError("Simple statement was not dispatched");
				case Try(tryBranch, catches, span):
					output.push(statementTyper.typeTry(tryBranch, catches, span, scope, result));
				case Defer(body, span):
					validateDeferredControl(body, 0);
					output.push(TDefer(typeStatements(body, new Scope(scope), result), span, false));
				case Break(span):
					throw new InternalError("Simple statement was not dispatched");
				case Continue(span):
					throw new InternalError("Simple statement was not dispatched");
				case Increment(name, delta, span):
					output.push(statementTyper.typeIncrement(name, delta, span, scope));
				case Assignment(name, expression, span):
					output.push(statementTyper.typeAssignment(name, expression, span, scope));
				case IndexAssignment(array, offset, expression, span):
					output.push(statementTyper.typeIndexAssignment(array, offset, expression, span, scope));
				case FieldAssignment(receiverExpression, fieldName, expression, span):
					output.push(statementTyper.typeFieldAssignment(receiverExpression, fieldName, expression, span,
						scope));
				case If(predicate, thenBranch, elseBranch, span):
					output.push(statementTyper.typeIf(predicate, thenBranch, elseBranch, span, scope, result));
				case While(predicate, body, span):
					output.push(statementTyper.typeWhile(predicate, body, span, scope, result));
				case DoWhile(body, predicate, span):
					output.push(statementTyper.typeDoWhile(body, predicate, span, scope, result));
				case ForIn(name, valueName, iterable, body, span):
					output.push(statementTyper.typeForIn(name, valueName, iterable, body, span, scope, result));
				case Switch(expression, cases, defaultBranch, hasDefault, span)
					if (ExtractorPatterns.present([for (switchCase in cases) switchCase.value])):
					// Extractor cases match as nested switches (`ExtractorPatterns`).
					for (typed in typeStatements(ExtractorPatterns.rewriteStatement(expression, cases, defaultBranch,
						hasDefault, span), scope, result))
						output.push(typed);
				case Switch(expression, cases, defaultBranch, hasDefault, span)
					if (StructurePatterns.present([for (switchCase in cases) switchCase.value])):
					// Structure patterns match as the tuple switch of the fields they name (`StructurePatterns`).
					var rewritten = StructurePatterns.rewrite(expression, [for (switchCase in cases) switchCase.value],
						span),
						statements:Array<AstStatement> = rewritten.temporary == null ? [] : [rewritten.temporary];
					statements.push(Switch(rewritten.subject, [for (index in 0...cases.length)
						{
							value:rewritten.values[index],
								guard:cases[index].guard,
								statements:cases[index].statements,
								span:cases[index].span
						}], defaultBranch, hasDefault, span));
					for (typed in typeStatements(statements, scope, result))
						output.push(typed);
				case Switch(expression, cases, defaultBranch, hasDefault, span):
					output.push(statementTyper.typeSwitch(expression, cases, defaultBranch, hasDefault, span, scope,
						result));
				case Expression(expression, span):
					throw new InternalError("Simple statement was not dispatched");
			}
		}
		return output;
	}

	static function isNoReturnPlaceholder(output:Array<TypedStatement>, statement:AstStatement):Bool {
		if (output.length == 0)
			return false;
		var previousIsNoReturn = switch output[output.length - 1] {
			case TExpression(expression, _): (switch (expression.type) {
					case TNever: true;
					default: false;
				});
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

	function knownExpressionType(expression:AstExpression, ?bindings:Map<String, CompilerType>):Null<CompilerType>
		return switch compiler.syntax.AstPredicates.unannotatedExpression(expression) {
			case Variable(name, _) if (bindings != null): bindings.get(name);
			case Call(name, _, _): knownCallType(name);
			case StringLiteral(_, _): TString;
			case IntegerLiteral(_, _): TInt;
			case FloatLiteral(_, _): TFloat;
			case BoolLiteral(_, _): TBool;
			case ArrayLiteral(values, _) if (values.length > 0): var element = knownExpressionType(values[0], bindings),
				homogeneous = element != null;
				for (index in 1...values.length) {
					var candidate = knownExpressionType(values[index], bindings);
					if (candidate == null || element == null || !sameType(candidate, element))
						homogeneous = false;
				}
				homogeneous && element != null ? TArray(element) : null;
			case Range(_, _, _): TRange;
			case New(typeName, _, span):
				if (session.declarations.abstracts.exists(typeName)) session.declarations.resolve(NamedType(typeName),
					span);
				else session.classDecls.exists(typeName) ? TInstance(NominalKind.Class, typeName, []) : null;
			default: null;
		};

	public function contextualExpressionType(expression:AstExpression, scope:Scope):Null<CompilerType> {
		var known = knownExpressionType(expression);
		if (known != null)
			return known;
		return switch compiler.syntax.AstPredicates.unannotatedExpression(expression) {
			case Variable(name, _): name.indexOf(".") >= 0 ? typeExpression(expression,
				scope).type : scope.resolve(name);
			case Member(_, _, _): typeExpression(expression, scope).type;
			case Cast(_, target, castSpan): target == null ? null : lowerType(target, castSpan);
			case CheckType(_, type, checkSpan): lowerType(type, checkSpan);
			default: null;
		};
	}

	function knownCallType(name:String):Null<CompilerType> {
		var signatureName = resolvedCallName(name);
		if (!session.signatures.exists(signatureName))
			return null;
		var signature = requiredMapValue(session.signatures, signatureName);
		return isGeneric(signature) ? null : functionResultType(signature, signature.span);
	}

	function resolvedCallName(name:String):String {
		var method = lexicalMethod(name);
		return method == null ? name : method.owner + "." + name;
	}

	public function lexicalMethod(name:String):Null<SemanticMethodInfo> {
		if (name.indexOf(".") >= 0 || context.lexicalOwner == null)
			return null;
		return findMethod(context.lexicalOwner, name);
	}

	function typeSwitchArrayPattern(value:AstExpression, expected:CompilerType,
			scope:Scope):Null<TypedSwitchArrayPattern> {
		return switch [value, expected] {
			case [ArrayLiteral(values, _), TArray(element)]: typeArrayPatternElements(values,
				[for (_ in values) element],
				scope);
			default: null;
		};
	}

	/** The element patterns of an array or tuple pattern, the one at each index typed as `elementTypes` gives. */
	function typeArrayPatternElements(values:Array<AstExpression>, elementTypes:Array<CompilerType>,
			scope:Scope):TypedSwitchArrayPattern {
		var elements:Array<TypedSwitchArrayElement> = [];
		for (index in 0...values.length) {
			var pattern = values[index], elementType = elementTypes[index];
			var capture = switchCapture(pattern, elementType, scope),
				elementPattern = capture == null ? pattern : capture.pattern,
				isWildcard = isSwitchCatchAll(elementPattern),
				subjectBinding = capture != null ? capture.name : isWildcard
					? null : switchSubjectBinding(elementPattern, elementType, scope),
				isCatchAll = isWildcard || capture == null && subjectBinding != null,
				enumPattern = isCatchAll ? null : typeEnumPattern(elementPattern, elementType, scope),
				typedValue:Null<TypedExpression> = null,
				equalityFunction:Null<String> = null,
				constructorIndex = -1,
				bindings:Array<TypedSwitchBinding> = [],
				predicates:Array<TypedSwitchPredicate> = [];
			if (enumPattern != null) {
				typedValue = enumPattern.value;
				constructorIndex = enumPattern.index;
				bindings = enumPattern.bindings;
				predicates = enumPattern.predicates;
			} else if (!isCatchAll) {
				typedValue = coerce(typeExpression(elementPattern, scope, elementType), elementType,
					"array switch pattern", "E1019");
				var literal = enumLiteral(typedValue);
				if (literal != null)
					constructorIndex = literal.index;
				if (literal == null && !AstPredicates.isNullExpression(elementPattern)) {
					var valueType = switch elementType {
						case TNullable(inner): inner;
						default: elementType;
					};
					var needsConformance = session.relations.isStruct(valueType) || (switch valueType {
						case TArray(_) | TAnonymous(_, _): true;
						default: false;
					});
					if (needsConformance && !DeclaredConformance.supportsEquality(session, elementType))
						fail("E1025",
							'Type "${compiler.semantic.SemanticSignature.display(elementType)}" does not conform to Equatable',
							typedValue.span);
					if (DeclaredConformance.usesEquality(session, elementType)) {
						var keyed = ValueEqualityGenerator.request(session, elementType, session.currentContext.name,
							typedValue.span);
						equalityFunction = ValueEqualityGenerator.equalsName(keyed);
					}
				}
			}
			elements.push({
				type: elementType,
				value: typedValue,
				equalityFunction: equalityFunction,
				subjectBinding: subjectBinding,
				isCatchAll: isCatchAll,
				constructorIndex: constructorIndex,
				bindings: bindings,
				predicates: predicates
			});
		}
		return {elements: elements};
	}

	/**
	 * Classifies one case of a tuple switch, `switch [a, b]`: as in Haxe, a case is `_` or an array pattern with one element
	 * per subject element, each typed as its own element. The tuple itself is no value, so no case can bind it.
	 */
	public function switchTuplePattern(value:AstExpression, elementTypes:Array<CompilerType>, caseSpan:SourceSpan,
			scope:Scope):SwitchTypingRules.SwitchCasePattern {
		var arrayPattern:Null<TypedSwitchArrayPattern> = null;
		switch value {
			case Variable("_", _):
			case ArrayLiteral(values, span):
				if (values.length != elementTypes.length)
					fail("E1019",
						'Tuple pattern has ${values.length} elements, but the switch subject has ${elementTypes.length}',
						span);
				arrayPattern = typeArrayPatternElements(values, elementTypes, scope);
			case Variable(_, span), Capture(_, _, span):
				fail("E1019", "Cannot bind matched tuple to variable, use _ instead", span);
			default:
				fail("E1019", 'Tuple switch case must be _ or an array pattern of ${elementTypes.length} elements',
					caseSpan);
		}
		return {
			value: value,
			subjectBinding: null,
			isCatchAll: arrayPattern == null,
			arrayPattern: arrayPattern,
			enumPattern: null
		};
	}

	public function switchArrayPatternKey(pattern:TypedSwitchArrayPattern):Null<String> {
		var keys:Array<String> = [];
		for (element in pattern.elements) {
			if (element.isCatchAll || element.value == null)
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
			case Variable(name, span):
				var info = patternConstructor(name, span, expected, scope);
				if (info == null || info.params.length != 0)
					return null;
				var instanceType = enumInstance(expected) ?? TInstance(NominalKind.Enum, info.enumName, []);
				{
					value:new TypedExpression(TEnumLiteral(info.enumName, info.index), instanceType, span, false, null,
						null, info.aliasName),
						enumName:info.enumName,
						index:info.index,
						bindings:[],
						predicates:[]
				};
			case Call(name, arguments, span):
				var info = patternConstructor(name, span, expected, scope);
				if (info == null)
					return null;
				var instanceType = enumInstance(expected) ?? TInstance(NominalKind.Enum, info.enumName, []);
				var required = requiredEnumParameters(info.params);
				if (arguments.length < required || arguments.length > info.params.length)
					fail("E1019", 'Enum switch case "$name" expects $required to ${info.params.length} bindings', span);
				var bindings:Array<TypedSwitchBinding> = [],
					predicates:Array<TypedSwitchPredicate> = [];
				for (index in 0...arguments.length) {
					var parameter = info.params[index],
						parameterType = enumParameterType(info.typeParameters, parameter, instanceType),
						abstractName = enumAbstractPatternName(parameter.type),
						storageType = session.representation.enumStorageType(info.typeParameters, parameter,
							instanceType);
					var argument = arguments[index];
					// `name = pattern` binds the whole payload value, then matches it against `pattern` as usual.
					while (true) {
						switch argument {
							case Capture(binding, pattern, bindingSpan):
								bindings.push(bindPatternName(binding, bindingSpan, scope, parameterType, storageType,
									index));
								argument = pattern;
								continue;
							default:
						}
						break;
					}
					switch argument {
						case Variable(binding, bindingSpan):
							var constantName = enumAbstractPatternConstant(abstractName, binding),
								owner = context.lexicalOwner,
								staticField = owner == null ? null : findStaticFieldNullable(owner, binding),
								inlineField = staticField == null
									? null : inlineConstantResolver.resolve(staticField.owner, binding, bindingSpan);
							if (binding == "_") {} else if (constantName != null
								|| inlineField != null
								|| patternConstructor(binding, bindingSpan, parameterType, scope) != null
								|| binding.indexOf(".") >= 0) {
								predicates.push(typeEnumPredicate(argument, parameterType, storageType, index,
									constantName));
							} else bindings.push(bindPatternName(binding, bindingSpan, scope, parameterType,
								storageType, index));
						case Call(_, _, _):
							var nested = typeEnumPattern(argument, parameterType, scope);
							if (nested == null) {
								predicates.push(typeEnumPredicate(argument, parameterType, storageType, index, null));
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
											enumType: parameterType,
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
											enumType: parameterType,
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
											fail("E1019", 'Unknown anonymous field "${field.name}" in enum pattern',
												field.span);
										switch field.value {
											case Variable("_", _):
											default:
												var typed = coerce(typeExpression(field.value, new Scope(),
													expectedField.type), expectedField.type,
													"enum object payload pattern", "E1019");
												if (constantPatternKey(typed) == null)
													fail("E1019",
														"Enum object payload patterns must be constants or '_'",
														patternSpan);
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
									fail("E1019", "Anonymous object payload patterns require an anonymous value",
										patternSpan);
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
											case Variable("_", _):
											// A name binds the element unless it names a constructor, which is matched.
											case Variable(binding, bindingSpan) if (patternConstructor(binding,
												bindingSpan, elementType, scope) == null):
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
											default:
												predicates.push(typeEnumPredicate(values[arrayIndex], elementType,
													elementStorage, index, null, arrayIndex,
													storageType));
										}
								default:
									fail("E1019", "Array payload pattern requires an Array value", patternSpan);
							}
						default:
							predicates.push(typeEnumPredicate(argument, parameterType, storageType, index, null));
					}
				}
				{
					value:new TypedExpression(TEnumLiteral(info.enumName, info.index), instanceType, span, false, null,
						null, info.aliasName),
						enumName:info.enumName,
						index:info.index,
						bindings:bindings,
						predicates:predicates
				};
			default: null;
		};
	}

	/** Classifies one case pattern, declaring the names it binds in `scope`. */
	public function switchCasePattern(value:AstExpression, expected:CompilerType,
			scope:Scope):SwitchTypingRules.SwitchCasePattern {
		var capture = switchCapture(value, expected, scope),
			pattern = capture == null ? value : capture.pattern,
			isWildcard = isSwitchCatchAll(pattern),
			subjectBinding = capture != null ? capture.name : isWildcard ? null : switchSubjectBinding(pattern,
				expected,
				scope), // A bare name binds and matches everything; a capture binds and still matches its pattern.
			isCatchAll = isWildcard || capture == null && subjectBinding != null,
			arrayPattern = isCatchAll ? null : typeSwitchArrayPattern(pattern, expected, scope),
			enumPattern = isCatchAll || arrayPattern != null ? null : typeEnumPattern(pattern, expected, scope);
		return {
			value: pattern,
			subjectBinding: subjectBinding,
			isCatchAll: isCatchAll,
			arrayPattern: arrayPattern,
			enumPattern: enumPattern
		};
	}

	/** Declares a name a pattern binds to the enum payload at `index`. */
	function bindPatternName(name:String, span:SourceSpan, scope:Scope, type:CompilerType, storageType:CompilerType,
			index:Int):TypedSwitchBinding {
		scope.define(name, type, span);
		bindCell(name, span, scope, type);
		return {
			name: scope.requireId(name),
			type: type,
			storageType: storageType,
			fieldStorageType: storageType,
			index: index,
			arrayIndex: -1
		};
	}

	/**
	 * A case written `name = pattern`: declares `name` as the matched subject and returns the pattern still to match, or null for
	 * any other case.
	 */
	function switchCapture(value:AstExpression, expected:CompilerType, scope:Scope):Null<{
		name:String,
		pattern:AstExpression
	}> {
		return switch value {
			case Capture(name, pattern, span):
				switch pattern {
					case Capture(_, _, innerSpan): fail("E1019", "A case value can be captured by only one name",
						innerSpan);
					default:
				}
				scope.define(name, expected, span);
				bindCell(name, span, scope, expected);
				{
					name:scope.requireId(name), pattern:pattern
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
				var info = patternConstructor(name, span, expected, scope);
				// Enum abstracts are erased to their underlying type, so the
				// subject cannot name its values; a bare value name resolves as
				// in any expression rather than binding the subject.
				if (info == null && scope.resolve(name) == null && isEnumAbstractValueName(name))
					return null;
				if (info != null) null;
				else if (name == "_") null;
				else {
					scope.define(name, expected, span);
					bindCell(name, span, scope, expected);
					scope.requireId(name);
				}
			default: null;
		}
	}

	/**
	 * The enum constructor a case pattern names, resolved as Haxe's matcher resolves it: a bare name is first looked up
	 * among the constructors of the enum the subject holds, so it wins over a constructor of the same name in another
	 * enum; otherwise the name resolves as in any expression, where a local or a static field shadows a constructor.
	 * Null when the name is no enum constructor. A constructor whose enum the subject cannot hold is an error, as in
	 * Haxe, rather than a pattern matching by constructor index.
	 */
	function patternConstructor(name:String, span:SourceSpan, expected:CompilerType,
			scope:Scope):Null<EnumConstructorInfo> {
		var expectedEnum = enumName(expected);
		if (span.isBareReference) {
			var sourceName = span.referenceName ?? name;
			if (expectedEnum != null) {
				var own = enumCaseInfo(expectedEnum + "." + lastPathSegment(sourceName));
				if (own != null)
					return own;
			}
			var owner = context.lexicalOwner;
			if (scope.resolve(sourceName) != null || owner != null
				&& findStaticFieldNullable(owner, sourceName) != null)
				return null;
		}
		var info = name.indexOf(".") >= 0 ? enumCaseInfo(name) : fileEnumCaseInfo(name, span);
		if (info != null && info.enumName != expectedEnum) {
			var found:CompilerType = TInstance(NominalKind.Enum, info.enumName, []),
				foundName = compiler.semantic.SemanticSignature.display(found),
				expectedName = compiler.semantic.SemanticSignature.display(expected),
				constructorName = lastPathSegment(name);
			if (!isAssignable(found, expected))
				fail("E1019",
					'$foundName should be $expectedName: the case pattern names constructor "$constructorName" of $foundName, but the value matched is $expectedName',
					span);
			// Haxe matches a constructor against a Dynamic value too; here only a value known to be of an enum can be matched.
			fail("E1019",
				'Constructor "$constructorName" of $foundName cannot be matched against a value of type $expectedName; give the matched value its enum type',
				span);
		}
		return info;
	}

	/** The constructor a bare name picks out among the enums declared in the file it is written in. */
	function fileEnumCaseInfo(name:String, span:SourceSpan):Null<EnumConstructorInfo> {
		for (entry in session.enumsInFile(span.file.path))
			for (index in 0...entry.declaration.cases.length) {
				var enumCase = entry.declaration.cases[index];
				if (enumCase.name == name)
					return {
						enumName: entry.name,
						index: index,
						params: enumCase.params,
						typeParameters: entry.declaration.typeParameters
					};
			}
		return null;
	}

	function isEnumAbstractValueName(name:String):Bool {
		for (candidate in session.declarations.enumAbstractList)
			for (value in candidate.values)
				if (value.name == name)
					return true;
		return false;
	}

	static function isSwitchCatchAll(value:AstExpression):Bool
		return switch value {
			case Variable(name, _): name == "_";
			default: false;
		};

	function typeEnumPredicate(value:AstExpression, type:CompilerType, storageType:CompilerType, index:Int,
			constantName:Null<String>, arrayIndex:Int = -1,
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
		var typed = coerce(typeExpression(resolvedValue, new Scope(), type), type, "enum payload pattern",
			"E1019");
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

	/** The enum abstract a payload of `type` holds, `Null<Kind>` included, whose value names a pattern matches as constants. */
	function enumAbstractPatternName(type:AstType):Null<String>
		return switch type {
			case NullableType(inner): enumAbstractPatternName(inner);
			case NamedType(name), AppliedType(name, _): session.enumAbstractName(name);
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
				&& objectPath.length == 0 ? 'array-length:${predicate.arrayLength}'
				: 'path:${path}:${objectPath}:array-length:${predicate.arrayLength}';
		var value = predicate.value;
		if (value == null)
			throw new InternalError("Equality payload predicate has no value");
		return path.length == 0
			&& objectPath.length == 0 ? Std.string(constantPatternKey(value))
			: 'path:${path}:${objectPath}:${Std.string(constantPatternKey(value))}';
	}

	public function switchCaseKey(value:TypedExpression, predicates:Array<TypedSwitchPredicate>):Null<String>
		return switch value.expression {
			case TIntLiteral(v): 'int:$v';
			case TStringLiteral(v): 'string:$v';
			case TBoolLiteral(v): 'bool:$v';
			case TEnumLiteral(name, index): enumPatternKey(name, index, predicates);
			case TNullLiteral: "null";
			case TNullableWrap(inner), TCast(inner), TAbiCast(inner),
				TParameterConversion(inner, _): switchCaseKey(inner, predicates);
			default: null;
		};

	public static function enumLiteral(value:TypedExpression):Null<{name:String, index:Int}>
		return switch value.expression {
			case TEnumLiteral(name, index): {name: name, index: index};
			case TNullableWrap(inner), TCast(inner), TAbiCast(inner),
				TParameterConversion(inner, _): enumLiteral(inner);
			default: null;
		};

	function constantPatternKey(value:TypedExpression):Null<String>
		return switch value.expression {
			case TIntLiteral(v): 'int:$v';
			case TFloatLiteral(v): 'float:$v';
			case TIntToFloat(inner): switch inner.expression {
					case TIntLiteral(v): 'float:$v';
					default: null;
				};
			case TBoolLiteral(v): 'bool:$v';
			case TStringLiteral(v): 'string:$v';
			case TEnumLiteral(name, index): 'enum:$name:$index';
			case TNullLiteral: "null";
			case TNullableWrap(inner): constantPatternKey(inner);
			case TCast(inner), TAbiCast(inner), TParameterConversion(inner, _): constantPatternKey(inner);
			default: null;
		};

	public function typeExpression(expression:AstExpression, scope:Scope, ?expectedType:CompilerType,
			inferDynamicLambdaResult:Bool = false):TypedExpression
		return expressionTyper.typeExpression(expression, scope, expectedType, inferDynamicLambdaResult);

	/** Dotted assignment syntax carries the statement span; each receiver still needs its own source range. */
	@:allow(compiler.types.typing.CallResolver)
	static function referencePrefixSpan(name:String, span:SourceSpan):SourceSpan {
		var size = span.file.utf8LengthAt(span.start, name);
		if (size < 0 || span.start + size > span.end)
			return span;
		return span.start + size == span.end ? span : new SourceSpan(span.file, span.start, span.start + size,
			span.isBareReference, span.referenceName);
	}

	public function typeVariableExpression(name:String, span:SourceSpan, scope:Scope,
			expectedType:Null<CompilerType>):TypedExpression {
		// Canonical module names are fallbacks: a source-level member takes precedence, including an inherited one.
		var sourceName = span.isBareReference ? span.referenceName : null,
			owner = context.lexicalOwner,
			thisType = scope.resolve("this");
		if (name != "this"
			&& sourceName != null
			&& sourceName.indexOf(".") < 0
			&& owner != null
			&& (findStaticFieldNullable(owner, sourceName) != null
			|| thisType != null
			&& findFieldType(thisType, sourceName) != null
			|| lexicalMethod(sourceName) != null))
			name = sourceName;
		span = referencePrefixSpan(name, span);
		// Haxe checks an instance field's typed initializer for `this`, which a member read through it is too.
		if (name == "this" && context.memberInitializer)
			fail("E1005", "Cannot access this or other member field in variable initialization", span);
		var type = scope.resolve(name);
		// A local whose type a use has since fixed reads as that type.
		if (type != null && session.monomorphs.active())
			type = compiler.types.Monomorphs.resolve(type);
		return if (type != null) {
			if (!scope.privateMapUseIsKnown(name, span))
				fail("E9001",
					'Internal compiler error: "$name" was analysed as a map nothing else can reach, but this use was not seen by that analysis',
					span);
			if (!scope.isAssigned(name))
				fail("E1023", 'Local "$name" may be used before assignment', span);
			var pathConstant = scope.keyPathConstant(name);
			if (pathConstant != null)
				return new TypedExpression(TCall(pathConstant, []), type, span);
			// A local proven null has no value of its own to read; the null itself has no ABI cast from the local's storage.
			if ((switch (type) {
				case TNull: true;
				default: false;
			})) {
				var declared = scope.resolveDeclared(name);
				if (declared != null)
					switch declared {
						case TNullable(_): return new TypedExpression(TNullableWrap(new TypedExpression(TNullLiteral,
							TNull, span)), declared, span);
						default:
					}
			}
			var value = new TypedExpression(scope.isCapture(name) ? (scope.isCellCapture(name) ? TCellCaptured(name,
				scope.requireCellClass(name)) : TCaptured(name)) : (boundCell(name,
				scope) != null ? TCellLocal(scope.requireId(name),
				requiredString(boundCell(name, scope))) : TLocal(name == "this" ? name : scope.requireId(name))),
				type, span, false, scope.mapKeySource(name), scope.isCapture(name)
				|| boundCell(name, scope) != null ? scope.resolveDeclared(name) : null);
			// An abstract's implementation reads `this` as its underlying value.
			// Keep the nominal receiver in scope for calls to its own methods.
			if (name == "this" && context.lexicalOwner != null
				&& session.declarations.abstracts.exists(context.lexicalOwner))
				switch type {
					case TAbstract(_, _, representation):
						value = session.representation.boundaryCast(value, representation);
					default:
				}
			value;
		} else {
			var owner = context.lexicalOwner;
			if (owner != null && name.indexOf(".") < 0) {
				var ownStatic = findStaticFieldNullable(owner, name);
				if (ownStatic != null) {
					var inlineValue = inlineStaticFieldExpression(ownStatic.owner, name, span);
					return inlineValue == null ? staticFieldValue(ownStatic.owner, name, ownStatic.type, span,
						scope) : inlineValue;
				}
				var thisType = scope.resolve("this");
				if (thisType != null && findFieldType(thisType, name) != null)
					return typedMemberWithFlow(implicitReceiver(span, scope), name, span, scope);
			}
			var enumLiteral = sourceIsBareReference(span) ? expectedEnumLiteral(name, expectedType, span) : null;
			if (enumLiteral != null)
				return enumLiteral;
			// A value of the enum abstract that is expected here outranks a class of the same name, as a
			// value of an expected enum does above; the class stays reachable wherever no value is expected.
			var abstractValue = sourceIsBareReference(span) ? expectedEnumAbstractValue(name, expectedType,
				span) : null;
			if (abstractValue != null)
				return abstractValue;
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
				new TypedExpression(TFunctionRef("__string_compare_full"), TFunction([TString, TString], TInt, []),
					span);
			else if (session.signatures.exists(functionName)) {
				var fn = requiredMapValue(session.signatures, functionName),
					types = argumentTypesOf(fn),
					methodInfo = session.methodInfo.get(functionName);
				// A static method value of a class or abstract (`C.m`); a module function has no method info.
				if (methodInfo != null)
					MemberAccess.method(session, methodInfo.owner,
						functionName.substr(functionName.lastIndexOf(".") + 1),
						span);
				// A function value is the dispatch entry when the function has one: a call through it may omit an argument.
				new TypedExpression(TFunctionRef(DefaultArguments.hasDispatchEntry(fn.arguments, types,
					session.relations) ? DefaultArguments.dispatchName(functionName) : functionName),
					dispatchFunctionType(fn, types, functionResultType(fn, fn.span)), span);
			}
				else if (session.externals.exists(name)) {
				var external = session.externals.get(name);
				new TypedExpression(TFunctionRef(name), TFunction(external.arguments, external.result, []), span);
			} else if (session.enumAbstractName(name) != null) {
				var abstractName = session.enumAbstractName(name);
				new TypedExpression(TClassRef(abstractName), TInstance(NominalKind.Class, abstractName, []), span);
			} else if (session.classDecls.exists(name) || PlatformAbi.isType(name))
				new TypedExpression(TClassRef(name), TInstance(NominalKind.Class, name, []), span);
			else if (session.classDecls.exists(AbstractStatics.storageName(name))) {
				// An abstract's statics, read through it (`Counter.count`), are its storage class's.
				var storage = AbstractStatics.storageName(name);
				new TypedExpression(TClassRef(storage), TInstance(NominalKind.Class, storage, []), span);
			} else {
				var owner = context.lexicalOwner,
					staticField:Null<{owner:String, type:CompilerType}> = null;
				if (owner != null)
					staticField = findStaticFieldNullable(owner, name);
				if (staticField != null) {
					var inlineValue = inlineStaticFieldExpression(staticField.owner, name, span);
					return inlineValue == null ? staticFieldValue(staticField.owner, name, staticField.type, span,
						scope) : inlineValue;
				}
				var dot = name.indexOf(".");
				if (dot <= 0) {
					var expectedEnumName = enumName(expectedType);
					if (expectedEnumName != null && session.enumDecls.exists(expectedEnumName)) {
						var expectedEnum = session.enumDecls.get(expectedEnumName);
						for (index in 0...expectedEnum.cases.length) {
							var enumCase = expectedEnum.cases[index];
							if (enumCase.name == name && enumCase.params.length == 0) {
								return new TypedExpression(TEnumLiteral(expectedEnum.name, index),
									enumLiteralType(expectedEnum, expectedType, span), span);
							}
						}
					}
					var expectedAbstractName = switch expectedType {
						case TAbstract(declaration, _, _): declaration;
						default: null;
					};
					var expectedAbstract = expectedAbstractName == null
						? null : session.enumAbstractDecls.get(expectedAbstractName);
					if (expectedAbstract == null && expectedAbstractName != null)
						for (candidateName => candidate in session.enumAbstractDecls)
							if (lastPathSegment(candidateName) == lastPathSegment(expectedAbstractName)) {
								expectedAbstract = candidate;
								break;
							}
					if (expectedAbstract != null) {
						for (value in expectedAbstract.values)
							if (value.name == name)
								return EnumAbstractValues.typed(this, expectedAbstract, value, span);
					}
					// Without an expected type, resolve a uniquely visible constant.
					var unqualifiedAbstract = findBareEnumAbstract(name, span);
					if (unqualifiedAbstract != null)
						for (value in unqualifiedAbstract.values)
							if (value.name == name)
								return EnumAbstractValues.typed(this, unqualifiedAbstract, value, span);
					var thisType = scope.resolve("this");
					if (thisType == null)
						fail("E1005", 'Unknown variable "$name"', span);
					var field = findFieldType(thisType, name);
					if (field == null)
						fail("E1005", 'Unknown variable "$name"', span);
					typedMemberWithFlow(implicitReceiver(span, scope), name, span, scope);
				} else {
					var parts = splitPath(name),
						objectName = parts[0],
						fieldName = parts[1],
						enumName = pathBeforeLast(name),
						enumCaseName = lastPathSegment(name);
					var enumAbstractName = session.enumAbstractName(enumName);
					if (enumAbstractName != null) {
						var enumAbstract = requiredMapValue(session.enumAbstractDecls, enumAbstractName);
						for (value in enumAbstract.values)
							if (value.name == enumCaseName)
								return EnumAbstractValues.typed(this, enumAbstract, value, span);
					}
					var qualifiedEnum = session.declarations.enumQualifierType(enumName),
						resolvedEnumName = BodyTyper.enumName(qualifiedEnum),
						qualifierName = enumName,
						isEnumAlias = resolvedEnumName != null && resolvedEnumName != enumName;
					if (resolvedEnumName != null) {
						enumName = resolvedEnumName;
						var enumDecl = requiredMapValue(session.enumDecls, enumName);
						var index = -1;
						for (i in 0...enumDecl.cases.length)
							if (enumDecl.cases[i].name == enumCaseName)
								index = i;
						if (index < 0)
							fail("E1005", 'Unknown enum case "$name"', span);
						if (enumDecl.cases[index].params.length > 0)
							fail("E1008", 'Enum case "$name" requires constructor arguments', span);
						var literalType:CompilerType = isEnumAlias ? qualifiedEnum : enumLiteralType(enumDecl,
							expectedType,
							span);
						return new TypedExpression(TEnumLiteral(enumName, index), literalType, span, false, null, null,
							isEnumAlias ? qualifierName : null);
					}
					var classEnd = parts.length - 1;
					while (classEnd > 0) {
						var className = parts.slice(0, classEnd).join(".");
						var abstractName = session.enumAbstractName(className);
						if (abstractName != null)
							className = abstractName;
						else if (session.classDecls.exists(AbstractStatics.storageName(className)))
							className = AbstractStatics.storageName(className);
						if (session.classDecls.exists(className) || abstractName != null
							|| PlatformAbi.isType(className)) {
							var classObject = new TypedExpression(TClassRef(className),
								TInstance(NominalKind.Class, className, []), span);
							for (index in classEnd...parts.length)
								classObject = typedMemberWithFlow(classObject, parts[index],
									referencePrefixSpan(parts.slice(0, index + 1).join("."), span),
									scope);
							return classObject;
						}
						classEnd--;
					}
					var object = typeExpression(Variable(objectName, span), scope);
					for (index in 1...parts.length)
						object = typedMemberWithFlow(object, parts[index],
							referencePrefixSpan(parts.slice(0, index + 1).join("."), span), scope);
					object;
				}
			}
		};
	}

	/** `statements` without the local `name`: its declaration goes, and each assignment to it only evaluates the value. */
	static function discardResult(statements:Array<AstStatement>, name:String):Array<AstStatement> {
		var result:Array<AstStatement> = [];
		for (statement in statements)
			switch statement {
				case UninitializedDeclaration(declared, _, _) if (declared == name):
				case Assignment(assigned, value, span) if (assigned == name):
					result.push(Expression(value, span));
				case Try(tryBranch, catches, span):
					result.push(Try(discardResult(tryBranch, name), [for (caught in catches)
						{
							name:caught.name, type:caught.type, statements:discardResult(caught.statements, name),
								span:caught.span
						}], span));
				case If(test, yes, no, span):
					result.push(If(test, discardResult(yes, name), discardResult(no, name), span));
				default:
					result.push(statement);
			}
		return result;
	}

	static function declaresUntyped(statements:Array<AstStatement>, name:String):Bool {
		for (statement in statements)
			switch statement {
				case UninitializedDeclaration(declared, InferredType, _) if (declared == name):
					return true;
				default:
			}
		return false;
	}

	public function typeBlockExpression(statements:Array<AstStatement>, result:AstExpression, span:SourceSpan,
			scope:Scope,
			expectedType:Null<CompilerType>):TypedExpression {
		// Result annotations are represented by a parser-generated local binding.
		// Fill only omitted parameter types from the surrounding function context;
		// keep the explicit result so an incompatible annotation is still rejected.
		var expression = BlockExpression(statements, result, span);
		var literal = LambdaSyntax.annotated(expression);
		if (literal != null && expectedType != null)
			switch statements[0] {
				case VarDeclaration(_, FunctionType(parameters, resultType, optional), _, _):
					switch expectedType {
						case TFunction(expectedParameters,
							expectedResult, _) if (parameters.length == expectedParameters.length):
							var resolved = [for (index in 0...parameters.length)
								switch parameters[index] {
									case InferredType:
										expectedParameters[index];
									case NullableType(InferredType):
										switch expectedParameters[index] {
											case TNullable(_): expectedParameters[index];
											default: TNullable(expectedParameters[index]);
										}
									default:
										session.declarations.resolve(parameters[index], span,
											context.typeSubstitutions);
								}];
							var result = session.declarations.resolve(resultType, span, context.typeSubstitutions);
							var value = typeExpression(literal, scope,
								TFunction(resolved, result, FunctionTypes.canonical(optional)));
							// An unbound generic result uses Dynamic as an inference hint.
							return (switch (expectedResult) {
								case TDynamic: true;
								default: false;
							}) ? value : coerce(value, expectedType, "annotated lambda", "E1003");
						default:
					}
				default:
			}
		// A block whose value is a local it declares without a type (a try expression's result) gives that local its expected
		// type; when the value is discarded, the local is not needed and what it would be assigned is only evaluated, so the
		// branches may differ in type, as Haxe allows for a try expression used as a statement.
		if (expectedType != null && expectedType.match(TVoid))
			switch result {
				case Variable(resultName, _) if (declaresUntyped(statements, resultName)):
					var evaluated = typeStatements(discardResult(statements, resultName), new Scope(scope),
						context.expectedReturnType);
					return new TypedExpression(TBlockExpression(evaluated,
						new TypedExpression(TVoidLiteral, TVoid, span)), TVoid, span);
				default:
			}
		if (expectedType != null && !expectedType.match(TVoid))
			switch result {
				case Variable(resultName,
					_) if (declaresUntyped(statements, resultName) && !context.resultLocalTypes.exists(resultName)):
					context.resultLocalTypes.set(resultName, expectedType);
				default:
			}
		var blockScope = new Scope(scope),
			typedStatements = typeStatements(statements, blockScope, context.expectedReturnType);
		if (ControlFlow.alwaysExits(typedStatements, function(type, cases) return this.exhaustiveSwitch(type, cases)))
			return new TypedExpression(TBlockExpression(typedStatements,
				new TypedExpression(TUnreachable, TNever, span)), TNever, span);
		var typedResult = typeExpression(result, blockScope, expectedType);
		if ((switch (expectedType) {
			case TVoid: true;
			default: false;
		}) && (switch (typedResult.type) {
			case TVoid: false;
			default: true;
		}) && (switch (typedResult.type) {
			case TNever: false;
			default: true;
		})) {
			typedStatements.push(TExpression(typedResult, typedResult.span));
			typedResult = new TypedExpression(TVoidLiteral, TVoid, typedResult.span);
		}
		// The final expression of a block is an expression branch, not a return
		// statement, so it does not pass through StatementTyper's return coercion.
		// TNull is also used as the provisional result while a switch expression is
		// still inferring its common branch type; defer coercion in that case so a
		// later non-null branch can widen the result to Null<T>.
		if (expectedType != null && (switch (expectedType) {
			case TNull: false;
			default: true;
		}) && (switch (expectedType) {
			case TVoid: false;
			default: true;
		}) && (switch (typedResult.type) {
			case TNever: false;
			default: true;
		}))
			typedResult = coerce(typedResult, expectedType, "block expression", "E1003");
		if ((switch (typedResult.type) {
			case TNever: false;
			default: true;
		})) {
			scope.join([blockScope]);
		}
		return new TypedExpression(TBlockExpression(typedStatements, typedResult), typedResult.type, span);
	}

	public function typeMember(object:AstExpression, name:String, span:SourceSpan, scope:Scope):TypedExpression {
		return typedMemberWithFlow(typeExpression(object, scope), name, span, scope);
	}

	function typeGenericCallArguments(fn:AstFunction, arguments:Array<AstExpression>, scope:Scope, span:SourceSpan):{
		arguments:Array<TypedExpression>,
		substitutions:Map<String, CompilerType>
	} {
		return callResolver.typeGenericCallArguments(fn, arguments, scope, span);
	}

	/** A read of a static field, with any branch-local null refinement applied. */
	function staticFieldValue(owner:String, name:String, type:CompilerType, span:SourceSpan,
			scope:Scope):TypedExpression {
		var property = ClassProperties.readStatic(session, this, owner, name, type, span, scope);
		if (property != null)
			return property;
		var field = new TypedExpression(TStaticField(owner, name), type, span),
			path = FlowAnalysis.accessPath(field),
			refined = path == null ? null : scope.resolveExpression(path);
		return refinedFieldValue(field, refined);
	}

	/** A proven-null field has a null value in its declared storage type, not an ABI cast to TNull. */
	function refinedFieldValue(field:TypedExpression, refined:Null<CompilerType>):TypedExpression {
		if ((switch (refined) {
			case TNull: true;
			default: false;
		}))
			switch field.type {
			case TNullable(_):
				return new TypedExpression(TNullableWrap(new TypedExpression(TNullLiteral, TNull, field.span)),
					field.type, field.span,
					field.stableFlowValue);
			default:
		}
		return refined == null
			|| sameType(field.type, refined) ? field : new TypedExpression(TCast(field), refined, field.span,
			field.stableFlowValue);
	}

	/**
	 * A null check only holds until something may change the value. Say which, instead of the bare "requires an object":
	 * a local assigned by a closure loses its check at any call that may run an escaped closure, and a field loses it at
	 * any assignment or call. Copying the checked value into a fresh local pins it.
	 */
	function explainNullableReceiver(object:TypedExpression, name:String, span:SourceSpan, scope:Scope):Void {
		switch object.type {
			case TNullable(_):
			default:
				return;
		}
		var reason = switch unwrappedCast(object).expression {
			case TLocal(id), TCellLocal(id, _), TCaptured(id),
				TCellCaptured(id, _) if (session.closureWritableNames(scope).indexOf(sourceName(id)) >= 0):
				var local = sourceName(id);
				'"$local" is assigned by a closure, so a call that may run an escaped closure clears its null check';
			case TField(_, _):
				var described = describeAccess(unwrappedCast(object));
				described == null ? null
					: 'the null check on "$described" no longer holds after an assignment or call that may have changed it';
			default:
				null;
		};
		if (reason != null)
			fail("E1005",
				'Field "$name" requires an object: $reason. Copy the checked value into a local ("var copy = value; if (copy != null) ...") and use the copy.',
				span);
	}

	/** A local's binding id reads "$l0:name"; the source name is what the reader wrote. */
	function sourceName(id:String):String {
		var colon = StringTools.startsWith(id, "$l") ? id.indexOf(":") : -1;
		return colon < 0 ? id : id.substr(colon + 1);
	}

	function unwrappedCast(expression:TypedExpression):TypedExpression {
		return switch expression.expression {
			case TCast(inner): inner;
			default: expression;
		};
	}

	function describeAccess(expression:TypedExpression):Null<String> {
		return switch expression.expression {
			case TLocal(id), TCellLocal(id, _), TCaptured(id), TCellCaptured(id, _): sourceName(id);
			case TField(object, field):
				var parent = describeAccess(object);
				parent == null ? null : parent + "." + field;
			default: null;
		};
	}

	public function typedMemberWithFlow(object:TypedExpression, name:String, span:SourceSpan,
			scope:Scope):TypedExpression {
		var objectPath = FlowAnalysis.accessPath(object);
		if (objectPath != null) {
			var refinedObject = scope.resolveExpression(objectPath);
			if (refinedObject != null && !sameType(object.type, refinedObject))
				object = new TypedExpression(TCast(object), refinedObject, object.span);
		}
		explainNullableReceiver(object, name, span, scope);
		var property = AbstractProperties.find(session, object.type, name);
		if (property != null)
			return callResolver.typeAbstractAccessorCall(object, AbstractProperties.accessor(session, property, true,
				span), [], span, scope);
		var member = typedMember(object, name, span),
			path = FlowAnalysis.accessPath(member);
		if (path == null)
			return member;
		var refined = scope.resolveExpression(path);
		return refinedFieldValue(member, refined);
	}

	function specializeGeneric(baseName:String, fn:AstFunction, arguments:Array<TypedExpression>, span:SourceSpan,
			scope:Scope, owner:Null<String>,
			isStatic:Bool, ?presetSubstitutions:Map<String, CompilerType>, ?receiver:TypedExpression):TypedExpression {
		return genericInstantiation.specialize(baseName, fn, arguments, span, scope, owner, isStatic,
			presetSubstitutions, receiver);
	}

	function inferTypeParameters(pattern:AstType, actual:CompilerType, parameters:Array<String>,
			substitutions:Map<String, CompilerType>, span:SourceSpan):Void
		return genericInstantiation.inferTypeParameters(pattern, actual, parameters, substitutions, span);

	/** Resolve and memoize an inline field so every use shares its typed value. */
	function resolveInlineConstant(owner:String, name:String, span:SourceSpan):Null<ResolvedInlineConstant>
		return inlineConstantResolver.resolve(owner, name, span);

	/** An inline field's initializer, against its annotation `expected`, or giving an unannotated one (`expected` null) its type. */
	public function typeInlineInitializer(expression:AstExpression, owner:String, name:String,
			expected:Null<CompilerType>,
			typeParameters:Array<String>):TypedExpression {
		var body = enterBody(owner + ".__inline", declarationTypeSubstitutions(owner, typeParameters), owner);
		var initializer:TypedExpression;
		try {
			var value = typeExpression(expression, new Scope(), expected);
			initializer = coerce(value, expected == null ? value.type : expected, 'inline field "$owner.$name"',
				"E1002");
		} catch (error:haxe.Exception) {
			leaveBody(body);
			throw error;
		}
		leaveBody(body);
		return initializer;
	}

	function rawPointerPointeeType(type:CompilerType):Null<CompilerType>
		return switch type {
			case TAbstract(name, arguments, _) if (name == "RawPtr" || StringTools.endsWith(name, ".RawPtr")):
				arguments.length == 1 ? arguments[0] : null;
			case _:
				null;
		};

	function flatRawPointerPointee(type:CompilerType):Null<CompilerType> {
		var pointee = rawPointerPointeeType(type);
		return switch pointee {
			case TInstance(NominalKind.Class, name, []) if (session.nativeLayoutsByName.exists(name)): pointee;
			case _: null;
		};
	}

	/** Resolve an inline static field to its memoized compile-time value. */
	function inlineStaticFieldExpression(owner:String, name:String, span:SourceSpan):Null<TypedExpression> {
		var resolved = resolveInlineConstant(owner, name, span);
		if (resolved != null) {
			recordInlineConstantDependency(owner + "." + name);
			for (target in resolved.dependencies)
				recordInlineConstantDependency(target);
		}
		return resolved == null ? null : new TypedExpression(resolved.value.expression, resolved.value.type, span,
			false, null, null, owner + "." + name);
	}

	/** Substitution must retain the dependencies erased by constant folding, including inside default arguments. */
	function recordInlineConstantDependency(target:String):Void {
		inlineConstantResolver.recordDependency(target);
		session.output.records.recordInlineConstantDependency(defaultArgumentCaller == null
			? context.name : defaultArgumentCaller,
			target);
	}

	public function typedMember(typedObject:TypedExpression, name:String, span:SourceSpan):TypedExpression {
		typedObject = TypeParameterMembers.receiver(session, this, typedObject, name, span);
		// A field of a Dynamic value is looked up when the program runs, and is itself Dynamic.
		if (sameType(typedObject.type, TDynamic)) {
			session.runtimeDependencyTracker.record(session.currentContext.name, "Reflect");
			return new TypedExpression(TCall("Reflect.field", [
				typedObject,
				new TypedExpression(TStringLiteral(name), TString, span)
			]), TDynamic, span);
		}
		switch typedObject.type {
			case TNullable(_):
				fail("E1005", 'Field "$name" requires an object', span);
			default:
		}
		if (name == "ref") {
			var pointee = rawPointerPointeeType(typedObject.type);
			if (pointee != null) {
				if (flatRawPointerPointee(typedObject.type) == null && !ExpressionTyper.deferredLayout(pointee))
					fail("E1022",
						'RawPtr.ref requires a Flat struct pointee; "$pointee" has no writable Flat field layout',
						span);
				return new TypedExpression(TCall("$rawptr.ref.flat", [typedObject]), pointee, span);
			}
		}
		switch typedObject.expression {
			case TClassRef(className):
				if (session.enumAbstractDecls.exists(className)) {
					var abstractDecl = requiredMapValue(session.enumAbstractDecls, className);
					for (value in abstractDecl.values)
						if (value.name == name)
							return EnumAbstractValues.typed(this, abstractDecl, value, span);
				}
				var staticField = findStaticField(className, name, span);
				MemberAccess.field(session, staticField.owner, name, true, span);
				var property = ClassProperties.readStatic(session, this, staticField.owner, name, staticField.type,
					span,
					null);
				if (property != null)
					return property;
				var inlineValue = inlineStaticFieldExpression(staticField.owner, name, span);
				return inlineValue == null ? new TypedExpression(TStaticField(staticField.owner, name),
					staticField.type, span) : inlineValue;
			default:
		}
		if (name == "length" && isArray(typedObject.type))
			return new TypedExpression(TArrayLength(typedObject), TInt, span);
		var forwardedArray = AbstractForwarding.arrayStorage(session, typedObject.type, name);
		if (name == "length" && forwardedArray != null)
			return new TypedExpression(TArrayLength(session.representation.boundaryCast(typedObject, forwardedArray)),
				TInt, span);
		var forwardedClass = AbstractForwarding.classStorage(session, typedObject.type, name);
		if (forwardedClass != null)
			return typedMember(session.representation.boundaryCast(typedObject, forwardedClass), name, span);
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
		if (platformField != null) {
			var module = PlatformAbi.sourceModule(platformField.get);
			if (module != null)
				session.runtimeDependencyTracker.record(session.currentContext.name, module);
			return new TypedExpression(TCall(platformField.get, [typedObject]), platformField.type, span);
		}
		var nominalOwner = switch typedObject.type {
			case TInstance(Class, className, _): className;
			default: null;
		};
		// A property is reached by its own visibility, not its accessor's (`get_x` is usually private), and its read side decides.
		var property = ClassProperties.instanceField(session, typedObject.type, name);
		if (property != null) {
			MemberAccess.requireField(session, property.declaration, property.field, span);
			ClassProperties.requireInstanceAccess(session, typedObject.type, name, true, span);
		}
		// An interface's variable or property is read through its interface's method (`InterfaceProperties`).
		var interfaceProperty = InterfaceProperties.find(session, typedObject.type, name);
		var getter = interfaceProperty != null ? InterfaceProperties.accessor(session, interfaceProperty, true,
			span) : ClassProperties.instanceAccessor(session, typedObject.type, name, true, typedObject, span);
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
				MemberAccess.method(session, resolvedMethodInfo.owner, name, span);
				if (session.relations.isValueClass(typedObject.type)
					&& !session.isPureCall(methodKey)
					&& !session.isReadOnlyReceiver(methodKey))
					ValuePlaceRules.rejectObservableMutation(session, typedObject, span);
				if (isGeneric(method))
					fail("E1007", "Generic instance method values are not supported yet", span);
				var substitutions = session.representation.nominalSubstitutions(projectNominal(typedObject.type,
					resolvedMethodInfo.owner)),
					arguments = session.declarations.types.argumentTypes(method, substitutions),
					result = session.declarations.types.resultType(method, substitutions);
				// A method value binds the dispatch entry when the method has one, as a virtual call reaches it.
				if (DefaultArguments.hasDispatchEntry(method.arguments, arguments, session.relations))
					return new TypedExpression(TMethodRef(typedObject, DefaultArguments.dispatchName(methodKey)),
						dispatchFunctionType(method, arguments, result), span);
				return new TypedExpression(TMethodRef(typedObject, methodKey),
					TFunction(arguments, result, FunctionTypes.ofArguments(method.arguments)), span);
			}
		}
		if (nominalOwner != null)
			MemberAccess.field(session, nominalOwner, name, false, span);
		var fieldRepresentation = session.representation.resolveField(typedObject.type, name, span),
			stableFlowValue = isStableFlowReceiver(typedObject) && isFinalInstanceField(typedObject.type, name);
		return session.representation.boundaryCast(new TypedExpression(TField(typedObject, name),
			fieldRepresentation.physical, span, stableFlowValue),
			fieldRepresentation.semantic);
	}

	static function isStableFlowReceiver(value:TypedExpression):Bool
		return switch value.expression {
			case TLocal(_), TCaptured(_): true;
			case TCast(inner), TAbiCast(inner), TParameterConversion(inner, _): isStableFlowReceiver(inner);
			case TField(_, _) if (value.stableFlowValue): true;
			default: false;
		};

	function isFinalInstanceField(type:CompilerType, name:String):Bool
		return switch type {
			case TInstance(NominalKind.Class, className, _):
				var declaration = session.classDecls.get(className);
				if (declaration == null) false;
				else {
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

	public static function unwrapNullable(value:TypedExpression):TypedExpression
		return switch value.type {
			case TNullable(element): new TypedExpression(value.expression, element, value.span);
			default: value;
		};

	/**
	 * A call of the property setter `setter` on `object` with `value`. As for a getter, the setter of a
	 * generic class takes and returns its type parameter's representation, not the substituted type.
	 */
	public function propertySetterCall(object:TypedExpression, setter:String, value:TypedExpression,
			span:SourceSpan):TypedExpression {
		var method = requiredMapValue(session.signatures, setter),
			methodInfo = session.methodInfo.get(setter),
			owner = methodInfo == null ? requiredString(parentPath(setter)) : methodInfo.owner,
			arguments = session.representation.adaptMethodArguments(object.type, owner, method, [value]),
			methodResult = session.representation.resolveMethodResult(object.type, owner, method);
		return new TypedExpression(TMethodCall(object, setter, arguments), methodResult.physical, span);
	}

	function fieldRepresentationType(type:CompilerType, name:String, span:SourceSpan):CompilerType
		return session.representation.resolveField(type, name, span).physical;

	public function findStaticField(className:String, name:String, span:SourceSpan):{owner:String, type:CompilerType} {
		var result = findStaticFieldNullable(className, name);
		if (result != null)
			return result;
		throw new CompileError(new Diagnostic("E1005",
			'Unknown static field "${AbstractStatics.displayOwner(className)}.$name"', span));
	}

	public function findStaticFieldNullable(className:String, name:String):Null<{owner:String, type:CompilerType}> {
		var found = MemberAccess.classField(session, className, name, true);
		return found == null ? null : {
			owner: found.declaration.name,
			type: session.declarations.types.fieldType(found.declaration.name, found.field, context.typeSubstitutions)
		};
	}

	public function rejectInlineFieldMutation(owner:String, name:String, span:SourceSpan):Void {
		var classDecl = session.classDecls.get(owner);
		if (classDecl == null)
			return;
		for (field in classDecl.fields)
			if (field.isStatic && field.isInline && field.name == name)
				fail("E1002", 'Cannot assign to inline field "$owner.$name"', span);
	}

	public function typeMethodCall(object:AstExpression, name:String, arguments:Array<AstExpression>, span:SourceSpan,
			scope:Scope,
			?expectedType:CompilerType):TypedExpression {
		var declared = typeExpression(object, scope), receiver = unwrapNullable(declared);
		if (callResolver.isEnumMatch(receiver, name, arguments))
			return callResolver.typeEnumMatch(object, arguments[0], span, scope);
		// A static extension may take the receiver as written, null included (`CallResolver.typeStaticExtensionCall`).
		return callResolver.typeMethodCall(receiver, name, arguments, span, scope, expectedType, true, null, true,
			declared == receiver ? null : declared);
	}

	/** The type of a value of `fn`, whose arguments have `types`: the signature of its dispatch entry (`DefaultArguments`). */
	function dispatchFunctionType(fn:AstFunction, types:Array<CompilerType>, result:CompilerType):CompilerType
		return TFunction([
			for (index in 0...fn.arguments.length)
				DefaultArguments.dispatchType(fn.arguments[index], types[index], session.relations)
		], result, FunctionTypes.ofArguments(fn.arguments));

	function coerceArguments(arguments:Array<TypedExpression>, expected:Array<CompilerType>,
			name:String):Array<TypedExpression> {
		return callResolver.coerceArguments(arguments, expected, name);
	}

	function typeCallArguments(arguments:Array<AstExpression>, expected:Array<CompilerType>, scope:Scope,
			name:String):Array<TypedExpression> {
		return callResolver.typeCallArguments(arguments, expected, scope, name);
	}

	/**
	 * `fn`'s argument types through the declaration query, in `substitutions` or, when none are given, the current body's: the
	 * callee-facing view, where `?x:T` and `x:T = null` are `Null<T>`.
	 */
	public function argumentTypesOf(fn:compiler.syntax.Ast.AstFunction,
			?substitutions:Map<String, CompilerType>):Array<CompilerType>
		return session.declarations.types.argumentTypes(fn,
			substitutions == null ? context.typeSubstitutions : substitutions);

	/** The type an unannotated argument's default value gives it, as the declaration query asks it (until slice 4 types it). */
	public function defaultValueType(value:AstExpression):Null<CompilerType>
		return knownExpressionType(value);

	static function isPosInfosParameter(argument:compiler.syntax.Ast.AstArgument):Bool
		return CallResolver.isPosInfosParameter(argument);

	public function typeDefaultExpression(expression:AstExpression, expected:CompilerType,
			declarationName:String):TypedExpression {
		// Defaults are resolved in the callee's scope but their substituted constants belong to the caller's artifact.
		var previousCaller = defaultArgumentCaller;
		if (defaultArgumentCaller == null)
			defaultArgumentCaller = context.name;
		var body = enterBody(TypingSession.defaultArgumentBody(requiredString(defaultArgumentCaller), declarationName),
			null,
			parentPath(declarationName));
		try {
			var typed = typeExpression(expression, new Scope(), expected);
			session.output.records.recordDefaultArgumentSource(defaultArgumentCaller,
				typed.span.generatedReason == null ? typed.span.file : null);
			leaveBody(body);
			defaultArgumentCaller = previousCaller;
			return typed;
		} catch (error:haxe.Exception) {
			leaveBody(body);
			defaultArgumentCaller = previousCaller;
			throw error;
		}
	}

	public function posInfosExpression(span:SourceSpan):AstExpression {
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

	public static function inheritanceName(type:AstType):String
		return switch type {
			case NamedType(name), AppliedType(name, _): name;
			default: throw new InternalError("Inheritance requires a nominal type");
		};

	function satisfiesDisposable(actual:CompilerType, contract:CompilerType):Bool {
		return switch actual {
			case TDynamic, TNull: false;
			default: session.relations.satisfiesConstraint(actual, contract);
		};
	}

	function scopedSource(value:TypedExpression):Null<String> {
		return switch value.expression {
			case TLocal(name), TCellLocal(name, _), TCaptured(name),
				TCellCaptured(name, _): this.context.scopedBindings.get(name);
			case TCopy(inner, _), TNullableWrap(inner), TCast(inner), TAbiCast(inner),
				TParameterConversion(inner, _): scopedSource(inner);
			default: null;
		};
	}

	public function coerce(value:TypedExpression, expected:CompilerType, context:String,
			code:String = "E1009"):TypedExpression {
		if ((switch expected {
			case TDynamic: true;
			default: false;
		})) {
			var name = scopedSource(value);
			if (name != null)
				fail("E1002", 'Scoped binding "$name" cannot be converted to Dynamic', value.span);
		}
		return conversionResolver.coerce(value, expected, context, code);
	}

	function isAssignable(actual:CompilerType, expected:CompilerType):Bool {
		return session.relations.isAssignable(actual, expected);
	}

	function findMethod(className:String, name:String):Null<SemanticMethodInfo> {
		return callResolver.findMethod(className, name);
	}

	function enumCaseInfo(name:String):Null<EnumConstructorInfo>
		return callResolver.enumCaseInfo(name);

	function enumParameterType(typeParameters:Array<String>, parameter:compiler.syntax.Ast.AstEnumParameter,
			instance:Null<CompilerType>):CompilerType {
		return session.representation.enumParameterType(typeParameters, parameter, instance);
	}

	static function requiredEnumParameters(parameters:Array<compiler.syntax.Ast.AstEnumParameter>):Int {
		var minimum = 0;
		for (index in 0...parameters.length)
			if (!parameters[index].optional)
				minimum = index + 1;
		return minimum;
	}

	public function fieldType(type:CompilerType, name:String, span:SourceSpan):CompilerType
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
				return new TypedExpression(TEnumLiteral(declaration.name, index),
					enumLiteralType(declaration, expectedType, span), span);
			}
		}
		return null;
	}

	/**
	 * The enum abstract value a bare name picks out where a value of `expectedType` is wanted. Enum
	 * abstracts lower to their underlying type, so the expected type only says which underlying type the
	 * value must have; the abstracts over it that declare the name compete as in `findBareEnumAbstract`.
	 * Null when nothing is expected or the name is not such a value (an ambiguous name is left to the
	 * ordinary lookup, which reports it). Only called for a bare reference.
	 */
	function expectedEnumAbstractValue(name:String, expectedType:Null<CompilerType>,
			span:SourceSpan):Null<TypedExpression> {
		var valueName = lastPathSegment(name), expected = expectedType;
		if (expected != null)
			switch expected {
				case TNullable(inner):
					expected = inner;
				default:
			}
		var owner = expected == null ? session.constants.enumAbstractConstantOwner : switch expected {
			case TAbstract(name, _, _) if (session.enumAbstractDecls.exists(name)): name;
			default: session.constants.enumAbstractConstantOwner;
		};
		var declaration = owner == null ? null : session.enumAbstractDecls.get(owner);
		if (declaration != null)
			for (value in declaration.values)
				if (value.name == valueName)
					return EnumAbstractValues.typed(this, declaration, value, span);
		return null;
	}

	/**
	 * The enum abstract an uncontextualized bare value name belongs to.
	 * Among several abstracts declaring the value, the one in the current type's own package wins: its
	 * types are visible without an import, as in Haxe. An ambiguity that leaves more than one is an
	 * error.
	 */
	function findBareEnumAbstract(name:String, span:SourceSpan):Null<compiler.syntax.Ast.AstEnumAbstract> {
		var found:Null<compiler.syntax.Ast.AstEnumAbstract> = null,
			ambiguous = false,
			samePackage:Array<compiler.syntax.Ast.AstEnumAbstract> = [],
			declaredBy:Array<String> = [];
		var ownerPackage = context.lexicalOwner == null ? null : pathBeforeLast(context.lexicalOwner);
		for (candidate in session.declarations.enumAbstractList) {
			var candidateName = candidate.name;
			for (value in candidate.values)
				if (value.name == name) {
					if (found != null)
						ambiguous = true;
					found = candidate;
					declaredBy.push(candidateName);
					if (pathBeforeLast(candidateName) == ownerPackage)
						samePackage.push(candidate);
				}
		}
		if (ambiguous) {
			if (samePackage.length != 1) {
				declaredBy.sort(Reflect.compare);
				fail("E1005",
					'Ambiguous enum abstract value "$name": it is declared by ${[for (owner in declaredBy) '"$owner"'].join(", ")}'
					+ (samePackage.length > 1 ? ", and more than one of them is in the current package"
					: ", and none of them is in the current package")
					+ '. Qualify it with its abstract, for example "${declaredBy[0]}.$name"',
					span);
			}
			found = samePackage[0];
		}
		return found;
	}

	function uniqueEnumLiteral(name:String, span:SourceSpan):Null<TypedExpression> {
		var enumName:Null<String> = null, index = -1;
		for (entry in session.enumsInFile(span.file.path)) {
			var declaration = entry.declaration;
			for (candidateIndex in 0...declaration.cases.length) {
				var enumCase = declaration.cases[candidateIndex];
				if (enumCase.name != name || enumCase.params.length != 0)
					continue;
				if (enumName != null)
					fail("E1005", 'Ambiguous enum value "$name"', span);
				enumName = entry.name;
				index = candidateIndex;
			}
		}
		if (enumName == null)
			return null;
		return new TypedExpression(TEnumLiteral(enumName, index),
			enumLiteralType(requiredMapValue(session.enumDecls, enumName), null, span), span);
	}

	/**
	 * The type of a constructor without arguments of `declaration`: the instance `expectedType` names with every type argument,
	 * else one whose type parameters what the value meets fixes (`GenericInstantiation.constructedEnumType`).
	 */
	function enumLiteralType(declaration:compiler.syntax.Ast.AstEnum, expectedType:Null<CompilerType>,
			span:SourceSpan):CompilerType {
		var expected = enumInstance(expectedType);
		return switch expected {
			case TInstance(Enum, name, arguments) if ((name:String) == declaration.name
				&& arguments.length == declaration.typeParameters.length):
				expected;
			default: genericInstantiation.constructedEnumType(declaration.name, declaration.typeParameters, null, span);
		};
	}

	static function sourceIsBareReference(span:SourceSpan):Bool
		return span.isBareReference;

	public function resolveReceiver(name:String, span:SourceSpan, scope:Scope):Null<TypedExpression> {
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
			return inlineValue == null ? staticFieldValue(staticField.owner, name, staticField.type, span,
				scope) : inlineValue;
		}
		if (session.classDecls.exists(name))
			return new TypedExpression(TClassRef(name), TInstance(NominalKind.Class, name, []), span);
		return null;
	}

	public function findFieldType(type:CompilerType, name:String):Null<CompilerType>
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
							found = session.declarations.types.fieldType(className, field,
								session.representation.nominalSubstitutions(type));
					var base = classDecl.base;
					if (found == null && base != null)
						found = findFieldType(session.declarations.resolve(base, classDecl.span,
							session.representation.nominalSubstitutions(type)), name);
				}
				found;
			case TInstance(Interface, _, _):
				var property = InterfaceProperties.find(session, type, name);
				property == null ? null : InterfaceProperties.typeOf(session, type, property);
			case TAbstract(_, _, _):
				var property = AbstractProperties.find(session, type, name);
				property == null ? null : AbstractProperties.typeOf(session, type, property);
			default: null;
		};

	/**
	 * A write of `expression` to the property `name` of `object`, a property that is only its accessors: a call to its setter, an
	 * abstract's (`AbstractProperties`) or an interface's (`InterfaceProperties`). Null when `object` has no such property.
	 */
	public function accessorPropertyWrite(object:TypedExpression, name:String, expression:AstExpression,
			span:SourceSpan,
			scope:Scope, ?assigned:AssignedValue):Null<TypedExpression> {
		var interfaceProperty = InterfaceProperties.find(session, object.type, name);
		if (interfaceProperty != null) {
			var setter = InterfaceProperties.accessor(session, interfaceProperty, false, span),
				type = InterfaceProperties.typeOf(session, object.type, interfaceProperty),
				value = coerce(typeExpression(expression, scope, type), type, 'field "$name"', "E1002");
			if (assigned != null)
				value = assigned.bind(value, value.type);
			// The interface's setter is any implementing class's: what it may change is unknown here.
			session.invalidateUnknownCall(scope);
			scope.invalidateField(name);
			var call = propertySetterCall(object, setter, value, span);
			return assigned == null ? call : assigned.setter(call);
		}
		var property = AbstractProperties.find(session, object.type, name);
		if (property == null)
			return null;
		var setter = AbstractProperties.accessor(session, property, false, span),
			type = AbstractProperties.typeOf(session, object.type, property),
			value = coerce(typeExpression(expression, scope, type), type, 'field "$name"', "E1002");
		if (assigned != null)
			value = assigned.bind(value, value.type);
		var call = callResolver.typeAbstractAccessorCall(object, setter, [value], span, scope);
		return assigned == null ? call : assigned.setter(call);
	}

	public function typeAssignmentValue(assignment:AstStatement, span:SourceSpan, scope:Scope):TypedExpression
		return statementTyper.typeAssignmentValue(assignment, span, scope);

	/**
	 * The receiver of a member named without one: `this`, as the abstract's own type in an abstract's method (where `this` itself
	 * reads as the underlying value), so its properties are found.
	 */
	public function implicitReceiver(span:SourceSpan, scope:Scope):TypedExpression {
		var receiver = typeExpression(Variable("this", span), scope), thisType = scope.resolve("this");
		return switch thisType {
			case TAbstract(_, _, _): session.representation.boundaryCast(receiver, thisType);
			default: receiver;
		};
	}

	public function enumCaseCovered(type:CompilerType, constructorIndex:Int,
			cases:Array<TypedSwitchCoverageCase>):Bool {
		if (!isEnum(type))
			return false;
		for (switchCase in cases)
			if (switchCase.guard == null
				&& (switchCase.isCatchAll || switchCase.constructorIndex == constructorIndex
				&& switchCase.predicates.length == 0))
				return true;
		// Arms that differ in one argument only, matched there by every value of a finite type: each constructor of an enum,
		// `true` and `false`, or each declared value of a closed enum abstract.
		var groups:Map<String, {values:Array<String>, seen:Map<String, Bool>}> = [];
		for (switchCase in cases) {
			if (switchCase.constructorIndex != constructorIndex || switchCase.guard != null
				|| switchCase.predicates.length != 1)
				continue;
			var predicate = switchCase.predicates[0],
				value = predicate.value;
			if (predicate.arrayLength >= 0 || predicate.arrayIndex >= 0)
				continue;
			var nested = predicate.nestedConstructorIndex,
				literal = value == null ? null : enumLiteral(value),
				matched = nested != null ? 'enum:$nested' : literal != null ? 'enum:${literal.index}' : value == null
					? null : constantPatternKey(value),
				values = finiteValueKeys(predicate.type);
			if (matched == null || values == null)
				continue;
			var nestedPath = [
				for (access in predicate.nestedPath ?? [])
					'${access.constructorIndex}.${access.fieldIndex}'
			].join("/"),
				key = '${predicate.index}:$nestedPath',
				group = groups.get(key);
			if (group == null) {
				group = {values: values, seen: []};
				groups.set(key, group);
			}
			group.seen.set(matched, true);
		}
		for (group in groups)
			if ([for (value in group.values) if (!group.seen.exists(value)) value].length == 0)
				return true;
		return false;
	}

	/**
	 * The keys of every value of a finite type, as `enumCaseCovered` matches an argument against them: `enum:N` for each
	 * constructor of an enum, `bool:true` and `bool:false`, or a closed enum abstract's declared values. Null for any other
	 * type. A null need not be among them: whether one must be matched is SwitchNullCoverage's question.
	 */
	function finiteValueKeys(type:CompilerType):Null<Array<String>> {
		switch type {
			case TBool | TNullable(TBool):
				return ["bool:true", "bool:false"];
			default:
		}
		var name = enumName(type);
		if (name != null) {
			var declaration = session.enumDecls.get(name);
			return declaration == null
				|| declaration.cases.length == 0 ? null : [for (index in 0...declaration.cases.length) 'enum:$index'];
		}
		var closed = closedEnumAbstractValues(type);
		return closed == null || closed.length == 0 ? null : [for (value in closed) if (value.key != "null") value.key];
	}

	/**
	 * The type a switch over `subject` compares its constant cases as: Int, String, Bool, or an enum abstract over Int or
	 * String, each also nullable, when `case null` is matched apart from the value. Null for subjects without constant cases.
	 */
	public function switchConstantType(subject:CompilerType):Null<CompilerType>
		return switch subject {
			case TInt | TString | TBool: subject;
			case TNullable(inner): switchConstantType(inner);
			default: EnumAbstractValues.switchable(session, subject) ? subject : null;
		};

	/**
	 * The declared values of a closed enum abstract, keyed as switch cases are (`int:N`, `string:S`), or null when `type`
	 * is not one. Flags combine their values, so their switches have no fixed set to cover.
	 */
	public function closedEnumAbstractValues(type:CompilerType):Null<Array<{name:String, key:String}>> {
		switch type {
			case TNullable(inner):
				var values = closedEnumAbstractValues(inner);
				if (values != null)
					values.push({name: "null", key: "null"});
				return values;
			default:
		}
		var name = switch type {
			case TAbstract(name, _, _): name;
			default: null;
		};
		var declaration = name == null ? null : session.enumAbstractDecls.get(name);
		if (declaration == null || FlagsGenerator.conforms(session, declaration))
			return null;
		var values = [];
		for (value in declaration.values) {
			var key = constantPatternKey(EnumAbstractValues.raw(this, declaration, value));
			if (key == null)
				return null;
			values.push({name: value.name, key: key});
		}
		return values;
	}

	/**
	 * Whether `cases` cover every value of an enum (each constructor) or Bool (`true` and `false`) subject. A null subject need not
	 * be matched, as in Haxe: an enum fails with a null access, and a `Null<Bool>` is read as `false`.
	 */
	public function exhaustiveSwitch(type:CompilerType, cases:Array<TypedSwitchCase>):Bool {
		switch type {
			case TBool | TNullable(TBool):
				var seen:Map<String, Bool> = [];
				for (switchCase in cases)
					if (switchCase.arm.guard == null) {
						if (switchCase.arm.isCatchAll)
							return true;
						var key = switchCaseKey(switchCase.arm.value, []);
						if (key != null)
							seen.set(key, true);
					}
				return seen.exists("bool:true") && seen.exists("bool:false");
			default:
		}
		var enumName = enumName(type);
		if (enumName == null || !session.enumDecls.exists(enumName))
			return false;
		var enumDecl = requiredMapValue(session.enumDecls, enumName),
			coverageCases:Array<TypedSwitchCoverageCase> = [for (switchCase in cases)
				{
					constructorIndex:switchCase.arm.constructorIndex,
						subjectBinding:switchCase.arm.subjectBinding,
						isCatchAll:switchCase.arm.isCatchAll,
						guard:switchCase.arm.guard,
						predicates:switchCase.arm.predicates
				}];
		for (index in 0...enumDecl.cases.length)
			if (!enumCaseCovered(type, index, coverageCases))
				return false;
		return true;
	}

	/** `span` is where `type` is written: a name that fails to resolve, or resolves ambiguously, is reported there. */
	/** The declared result of `fn` (DeclarationIndex.resultType) with this body's type substitutions. */
	public function functionResultType(fn:AstFunction, span:SourceSpan):CompilerType
		return session.declarations.types.resultType(fn, context.typeSubstitutions);

	public function lowerType(type:AstType, span:SourceSpan):CompilerType
		return session.representation.semanticType(type, span, context.typeSubstitutions);

	static function copyMap<T>(source:Map<String, T>):Map<String, T> {
		var result:Map<String, T> = [];
		for (name => value in source)
			result.set(name, value);
		return result;
	}

	static function requiredMapValue<T>(source:Map<String, T>, name:String):T {
		if (!source.exists(name))
			throw new InternalError('Missing map entry "$name"');
		return source.get(name);
	}

	static function isGeneric(fn:AstFunction):Bool
		return functionTypeParameters(fn).length > 0;

	public static function functionTypeParameters(fn:AstFunction):Array<String> {
		var parameters = fn.typeParameters;
		if (parameters == null)
			return [];
		return parameters;
	}

	/** The index of a `Dynamic` value, which must be an Int as Haxe requires (`d["key"]` is an error there too). */
	public function dynamicIndex(index:TypedExpression):TypedExpression
		return coerce(ConversionResolver.plainValue(index, this), TInt, "array index", "E1014");

	public function arrayElementType(type:CompilerType, span:SourceSpan):CompilerType
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

	public static function isEnum(type:CompilerType):Bool
		return switch type {
			case TInstance(Enum, _, _): true;
			case TNullable(inner), TAbstract(_, _, inner): isEnum(inner);
			default: false;
		};

	public static function isNullableEnum(type:CompilerType):Bool
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
			case TString, TDynamic, TInstance(Class, _, []), TInstance(Interface, _, []), TAnonymous(_, _), TArray(_),
				TIterator(_), TFunction(_, _, _),
				TMap(_, _): true;
			default: false;
		};

	static function anonymousField(fields:Null<Array<compiler.types.Type.AnonymousField>>,
			name:String):Null<compiler.types.Type.AnonymousField> {
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
			case ErrorStatement(span), PrivateAccessStatement(_, span): span;
			case UninitializedDeclaration(_, _, span), VarDeclaration(_, _, _, span), ScopedDeclaration(_, _, _, span),
				Assignment(_, _, span),
				IndexAssignment(_, _, _, span), FieldAssignment(_, _, _, span), Return(_, span), ReturnVoid(span),
				Throw(_, span), Defer(_, span),
				Try(_, _, span), If(_, _, _, span), While(_, _, span), DoWhile(_, _, span), ForIn(_, _, _, _, span),
				Break(span), Continue(span),
				Switch(_, _, _, _, span), Increment(_, _, span), Expression(_, span): span;
		}

	@:noReturn
	static function fail(code:String, message:String, span:SourceSpan):Void
		throw new CompileError(new Diagnostic(code, message, span));

	static function sameType(left:CompilerType, right:CompilerType):Bool
		return TypeRelations.equals(left, right);
}
