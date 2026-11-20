package compiler.types.typing;

import compiler.core.Diagnostic;
import compiler.core.Diagnostic.CompileError;
import compiler.core.InternalError;
import compiler.core.Source.SourceSpan;
import compiler.semantic.SemanticSignature;
import compiler.syntax.Ast.AstFunction;
import compiler.syntax.Ast.AstType;
import compiler.syntax.AstFunctions;
import compiler.types.Type.CompilerType;
import compiler.types.TypeRelations;
import compiler.types.IterationProtocol;
import compiler.types.Monomorphs;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.analysis.Scope;

/** Resolves generic substitutions and requests/reuses emitted function specializations. */
class GenericInstantiation {
	final session:TypingSession;
	final bodyTyper:BodyTyping;

	/**
	 * Make each specialization's code from the body's own-parameter typing, through the elaboration pass
	 * (`CompileOptions.elaborateGenerics`).
	 */
	public var elaborateGenerics = false;

	public function new(session:TypingSession, bodyTyper:BodyTyping) {
		this.session = session;
		this.bodyTyper = bodyTyper;
	}

	public function specialize(baseName:String, fn:AstFunction, arguments:Array<TypedExpression>, span:SourceSpan,
			scope:Scope, owner:Null<String>,
			isStatic:Bool, ?presetSubstitutions:Map<String, CompilerType>, ?receiver:TypedExpression):TypedExpression {
		var required = fn.arguments.length;
		while (required > 0 && compiler.syntax.AstPredicates.isOptionalArgument(fn.arguments[required - 1]))
			required--;
		if (arguments.length < required || arguments.length > fn.arguments.length) {
			var expected = required == fn.arguments.length ? '$required' : '$required to ${fn.arguments.length}';
			fail("E1008", 'Function "$baseName" expects $expected arguments, got ${arguments.length}', span);
		}
		var substitutions:Map<String, CompilerType> = presetSubstitutions == null
			? [] : [for (parameter => type in presetSubstitutions) parameter => type],
			parameters = functionTypeParameters(fn);
		for (i in 0...arguments.length)
			inferArgumentTypeParameters(fn, i, fn.arguments[i], arguments[i].type, parameters, substitutions,
				arguments[i].span);
		for (parameter in parameters)
			if (!substitutions.exists(parameter))
				fail("E1003", 'Cannot infer generic type parameter "$parameter" for "$baseName"', span);
		settleTypeArguments(baseName, fn, arguments, substitutions, span);
		// The specialization is a unit of its own, named after its type arguments: a literal's structure among them closes here.
		for (parameter in [for (parameter in substitutions.keys()) parameter])
			substitutions.set(parameter, session.monomorphs.closeReached(requiredMapValue(substitutions, parameter)));
		var constraints = fn.typeConstraints;
		if (constraints != null)
			for (constraint in constraints) {
				var actual = requiredMapValue(substitutions, constraint.parameter),
					expected = session.declarations.resolve(constraint.type, constraint.span, substitutions);
				if (!session.relations.satisfiesConstraint(actual, expected)) {
					var detail = session.relations.constraintFailure(actual, expected);
					fail(session.relations.recursiveCapabilityFailure(actual, expected) ? "E1025" : "E1003",
						'Type argument for "${constraint.parameter}" does not satisfy constraint "${SemanticSignature.type(expected)}"'
						+ (detail == null ? "" : ': $detail'),
						span);
				}
			}
		var semanticExpected = bodyTyper.argumentTypesOf(fn, substitutions);
		for (index in arguments.length...fn.arguments.length) {
			var parameter = fn.arguments[index],
				defaultValue = parameter.defaultValue,
				expected = semanticExpected[index];
			if (CallResolver.isPosInfosParameter(parameter))
				arguments.push(bodyTyper.coerce(bodyTyper.typeExpression(bodyTyper.posInfosExpression(span), scope,
					expected), expected,
					'position argument ${index + 1} to "$baseName"'));
			else if (defaultValue == null)
				arguments.push(bodyTyper.coerce(new TypedExpression(TNullLiteral, TNull, span), expected,
					'default argument ${index + 1} to "$baseName"'));
			else
				arguments.push(bodyTyper.coerce(bodyTyper.typeDefaultExpression(parameter, expected, baseName),
					expected,
					'default argument ${index + 1} to "$baseName"'));
		}
		// An iterable parameter is structural, but a generic body can keep its concrete
		// collection representation. Include it in the specialization identity so
		// arrays retain indexed loops and classes retain direct method dispatch.
		var concrete:Array<CompilerType> = [],
			specializedArguments = fn.arguments.copy();
		var semanticArguments:Array<TypedExpression> = [];
		var hasIterationParameter = false;
		for (expected in semanticExpected)
			if (IterationProtocol.name(expected) != null)
				hasIterationParameter = true;
		var mutableAliases:Map<String, Bool> = hasIterationParameter
			? compiler.types.analysis.MutableIterationAliases.ofFunction(fn) : [];
		for (index in 0...arguments.length) {
			var argument = arguments[index],
				expected = semanticExpected[index];
			if (IterationProtocol.name(expected) != null
				&& (switch (argument.type) {
					case TNull: false;
					default: true;
				})
					&& (switch (argument.type) {
				case TNever: false;
				default: true;
			})
				&& !mutableAliases.exists(compiler.types.analysis.BindingWalker.key(fn.arguments[index].name,
				fn.arguments[index].span))) {
				// The value's element meets the parameter's, as a coerced argument's type does: `Lambda.has([], 3)` makes `[]` an
				// Array<Int>.
				var iterates = IterationProtocol.name(expected) == "Iterable",
					actualElement = IterationProtocol.element(session.declarations, argument.type, iterates),
					expectedElement = IterationProtocol.element(session.declarations, expected, iterates);
				if (actualElement != null && expectedElement != null)
					Monomorphs.unify(actualElement, expectedElement);
				if (!session.relations.isAssignable(argument.type, expected))
					fail("E1009", 'Type mismatch for iterable argument ${index + 1} to "$baseName"', argument.span);
				var hidden = "$iteration-argument:" + index,
					parameter = fn.arguments[index];
				var iterable = session.monomorphs.closeReached(argument.type);
				substitutions.set(hidden, iterable);
				specializedArguments[index] = {
					name: parameter.name,
					type: NamedType(hidden),
					optional: parameter.optional,
					defaultValue: parameter.defaultValue,
					span: parameter.span
				};
				concrete.push(iterable);
				semanticArguments.push(argument);
			} else {
				// Keep protocol positions in the key even when null or mutable storage
				// requires erasure; otherwise two calls can specialize different slots
				// under the same concrete-type list.
				if (IterationProtocol.name(expected) != null)
					concrete.push(expected);
				semanticArguments.push(bodyTyper.coerceArgument(argument, expected, baseName, index + 1));
			}
		}
		if (concrete.length > 0)
			fn = AstFunctions.withArguments(fn, specializedArguments);
		var constants:Map<String, String> = [],
			constantIndices:Map<Int, Bool> = [],
			constantPolicies:Array<String> = [],
			assigned = compiler.types.analysis.BodyResolution.of(fn.arguments, fn.statements).writes();
		for (index in 0...semanticArguments.length) {
			var definition = KeyPathTyping.known(session, semanticArguments[index]),
				parameter = fn.arguments[index];
			if (definition != null
				&& !assigned.exists(compiler.types.analysis.BindingWalker.key(parameter.name, parameter.span))) {
				constants.set(parameter.name, definition.name);
				constantIndices.set(index, true);
				constantPolicies.push("keypath:" + index + "=" + definition.name);
			}
		}
		var abstractDeclaration = receiver == null || owner == null ? null : session.declarations.abstracts.get(owner),
			genericCall = session.representation.resolveGenericCall(fn, substitutions, semanticArguments,
				(callee, calleeSubstitutions) -> bodyTyper.argumentTypesOf(callee, calleeSubstitutions),
				abstractDeclaration == null ? null : abstractDeclaration.underlying),
			genericRepresentation = genericCall.representation,
			representationSubstitutions = genericRepresentation.substitutions,
			specializationPolicies = genericRepresentation.policies.concat(constantPolicies),
			representationResult = genericCall.result.physical,
			representationArguments = genericCall.typeArguments.concat(concrete),
			specialization = session.genericSpecializations.request(baseName, representationArguments,
				specializationPolicies),
			result = genericCall.result.semantic,
			typed = [
				for (index in 0...genericCall.arguments.length) if (!constantIndices.exists(index))
					genericCall.arguments[index]
			];
		session.keyPaths.setConstants(specialization.name, constants);
		var representationReceiver:Null<CompilerType> = null;
		if (receiver != null)
			representationReceiver = session.declarations.abstracts.exists(requiredString(owner))
				? abstractReceiverType(requiredString(owner),
				representationSubstitutions) : receiver.type;
		session.useSharedUnit(specialization.name);
		typeSpecializationBody(specialization.name, fn, owner, receiver == null ? isStatic : true,
			representationReceiver, representationSubstitutions, representationArguments, false);
		if (receiver != null) {
			var receiverType = representationReceiver;
			if (receiverType == null)
				throw new InternalError("Generic receiver representation was not resolved");
			typed.unshift(session.representation.boundaryCast(receiver, receiverType));
		}
		var call = new TypedExpression(TCall(specialization.name, typed), representationResult, span);
		session.invalidateCallEffects(baseName, scope);
		return session.representation.boundaryCast(call, result);
	}

	/**
	 * A specialization is named and typed after its type arguments when the call is typed, so they must be known then. One that is
	 * an empty type variable only an argument's own value carries (`Lambda.empty([])`, whose element type nothing else can fix) is
	 * Dynamic already, as Haxe makes it, and settles here. One that something after the call could still fix (a local's, or one
	 * the call's result carries) is an error: a specialization cannot follow it. The call's lambdas are typed already, so they fix
	 * nothing later and do not count as carriers. An unannotated function's result is the one its body gives it.
	 */
	function settleTypeArguments(baseName:String, fn:AstFunction, arguments:Array<TypedExpression>,
			substitutions:Map<String, CompilerType>, span:SourceSpan):Void {
		var result = session.declarations.types.resultType(fn, substitutions);
		for (parameter in substitutions.keys())
			for (cell in Monomorphs.unboundCells(requiredMapValue(substitutions, parameter))) {
				if (!Monomorphs.isUnbound(TMonomorph(cell)))
					continue;
				var carriers = [
					for (argument in arguments)
						if (Monomorphs.mentions(cell, argument.type) && !argument.expression.match(TLambda(_, _, _)))
						argument
				];
				// A variable no other argument carries is a lambda's result's, which its body left empty (`opt(i -> null)`): Haxe
				// leaves it unknown, so Dynamic, even where the call's result mentions it.
				var lambdaOnly = carriers.length == 0;
				if (lambdaOnly ? session.monomorphs.carriedOnlyBy(cell, span) : !Monomorphs.mentions(cell, result)
					&& carriers.length == 1 && session.monomorphs.carriedOnlyBy(cell, carriers[0].span))
					Monomorphs.unify(TMonomorph(cell), TDynamic);
				else
					fail("E1003",
						'Cannot infer ${cell.origin} where it is passed to "$baseName": a generic call needs its type arguments'
						+ ' when it is typed; give it a type',
						cell.span);
			}
	}

	/**
	 * Types the body of the specialization `name` of `fn` once, as a shared unit of its own, unless it was typed already: the unit
	 * is merged where its first user in declaration order used it (`TypingSession.useSharedUnit`). One for type parameters is met
	 * only where a generic body is checked with its type parameters as themselves: it is checked as well, and is no code of the
	 * program. With `unused`, no user has asked for it yet, so it is typed into an output of its own wherever typing is.
	 */
	function typeSpecializationBody(name:String, fn:AstFunction, owner:Null<String>, isStatic:Bool,
			receiver:Null<CompilerType>, substitutions:Map<String, CompilerType>,
			representationArguments:Array<CompilerType>, unused:Bool):Void {
		if (session.emittedGenericBodies.exists(name))
			return;
		session.emittedGenericBodies.set(name, true);
		var forParameters = false;
		for (argument in representationArguments)
			if (session.representation.containsTypeParameter(argument, []))
				forParameters = true;
		session.typeSharedUnit(name,
			() -> session.closureConversion.addFunction(elaborateGenerics && !forParameters ? elaboratedBody(name, fn,
			owner, isStatic, receiver, substitutions) : bodyTyper.typeFunction(fn, owner, isStatic, substitutions, name,
			receiver)), forParameters, unused);
	}

	/**
	 * The specialization `name` of `fn` made by the elaboration pass: the body typed with its own and its owner's type parameters
	 * as themselves, then elaborated for `substitutions` (`CompileOptions.elaborateGenerics`).
	 */
	function elaboratedBody(name:String, fn:AstFunction, owner:Null<String>, isStatic:Bool, receiver:Null<CompilerType>,
			substitutions:Map<String, CompilerType>):compiler.types.TypedAst.TypedFunction {
		var key = owner == null ? fn.name : owner + "." + fn.name,
			own:Map<String, CompilerType> = [],
			ownerParameters = ownerTypeParameters(owner);
		for (parameter in ownerParameters)
			own.set(parameter, TTypeParameter(requiredString(owner), parameter));
		for (parameter in functionTypeParameters(fn))
			if (!own.exists(parameter))
				own.set(parameter, TTypeParameter(key, parameter));
		// The other substitutions are the specialization's own (an iteration argument's protocol type): the same in both typings.
		for (name => type in substitutions)
			if (!own.exists(name) && ownerParameters.indexOf(name) < 0 && functionTypeParameters(fn).indexOf(name) < 0)
				own.set(name, type);
		var ownReceiver = receiver == null ? null : session.declarations.abstracts.exists(requiredString(owner))
			? abstractReceiverType(requiredString(owner), own) : TInstance(Class, requiredString(owner),
			[for (parameter in ownerParameters) TTypeParameter(requiredString(owner), parameter)]);
		return bodyTyper.typeFunction(fn, owner, isStatic, own, name, ownReceiver, null, null, null,
			new GenericElaboration(owner == null ? [key] : [requiredString(owner), key], substitutions, bodyTyper));
	}

	/** The type parameters of the class or abstract `owner`, none for a module function. */
	function ownerTypeParameters(owner:Null<String>):Array<String> {
		if (owner == null)
			return [];
		var abstractDecl = session.declarations.abstracts.get(owner);
		if (abstractDecl != null)
			return abstractDecl.typeParameters;
		var classDecl = session.classDecls.get(owner);
		return classDecl == null ? [] : classDecl.typeParameters;
	}

	/**
	 * Types the one body of `fn`, a member of the non-generic abstract `owner` whose code is typed per call (an instance method, or
	 * the constructor normalized, `instanceMember` false): the specialization every call without an iteration or key-path argument
	 * makes, as `specialize` names it. It is typed once, here or by the first call, and reused by the other; a call records its use,
	 * so a body nothing calls is typed for its errors and never merged.
	 */
	public function typeMemberBody(baseName:String, fn:AstFunction, owner:String, instanceMember:Bool):Void {
		var underlying = instanceMember ? requiredMapValue(session.declarations.abstracts, owner).underlying : null,
			representation = session.representation.genericFunction(fn, [], underlying),
			specialization = session.genericSpecializations.request(baseName, [], representation.policies),
			constants:Map<String, String> = [];
		session.keyPaths.setConstants(specialization.name, constants);
		typeSpecializationBody(specialization.name, fn, owner, true,
			instanceMember ? abstractReceiverType(owner, representation.substitutions) : null,
			representation.substitutions, [], true);
	}

	/**
	 * The instance of the enum `name` that one of its constructors makes where no expected type names one, as Haxe types it: each
	 * type parameter in `typeParameters` is what `inferred` gives from the arguments (`Some(Move(4))` is an `Option<Ins>`), else a
	 * type variable that what the value meets fixes (`var o = None; o = Some(1);`), settled like a local's (`Monomorphs`), or
	 * Dynamic where no body is being typed. Null, Void and Never fix nothing.
	 */
	public function constructedEnumType(name:String, typeParameters:Array<String>,
			inferred:Null<Map<String, CompilerType>>,
			span:SourceSpan):CompilerType
		return TInstance(Enum, name, [for (parameter in typeParameters) {
			var type = inferred == null ? null : inferred.get(parameter);
			switch type {
				case null | TNull | TVoid | TNever:
					session.monomorphs.create('the type parameter "$parameter" of $name', span) ?? TDynamic;
				default: type;
			}
		}]);

	/**
	 * Infers `parameters` from the value `actual` passed as argument `index` (`argument`) of `fn`: from its annotation, or, for an
	 * unannotated argument, from the type the function's body gave it, which is in the function's own and its owner's type
	 * parameters as an annotation is (`DeclarationTypeTable.inferredArgumentType`). Without `fn` (an enum constructor's
	 * parameters), from the annotation.
	 */
	public function inferArgumentTypeParameters(fn:Null<AstFunction>, index:Int,
			argument:compiler.syntax.Ast.AstArgument,
			actual:CompilerType, parameters:Array<String>, substitutions:Map<String, CompilerType>,
			span:SourceSpan):Void {
		if (fn == null || !AstFunctions.isInferred(argument.type)) {
			inferTypeParameters(argument.type, actual, parameters, substitutions, span);
			return;
		}
		var pattern = inferredArgumentPattern(fn, index);
		if (pattern != null)
			inferFromType(pattern, actual, parameters, substitutions, span);
	}

	/** The type argument `index` of `fn` expects once `substitutions` binds every type parameter it mentions. */
	public function expectedArgumentType(fn:Null<AstFunction>, index:Int, argument:compiler.syntax.Ast.AstArgument,
			substitutions:Map<String, CompilerType>):CompilerType {
		if (fn == null || !AstFunctions.isInferred(argument.type))
			return session.declarations.resolve(argument.type, argument.span, substitutions);
		var pattern = inferredArgumentPattern(fn, index);
		return pattern == null ? TDynamic : DeclarationTypeTable.substitute(pattern, substitutions);
	}

	function inferredArgumentPattern(fn:AstFunction, index:Int):Null<CompilerType> {
		var table = session.types;
		return table == null ? null : table.inferredArgumentType(fn, index);
	}

	/** `inferTypeParameters` for a pattern that is a resolved type, whose type parameters are `TTypeParameter`s. */
	function inferFromType(pattern:CompilerType, actual:CompilerType, parameters:Array<String>,
			substitutions:Map<String, CompilerType>, span:SourceSpan):Void {
		function each(patterns:Array<CompilerType>, actuals:Array<CompilerType>):Void
			if (patterns.length == actuals.length)
				for (index in 0...patterns.length)
					inferFromType(patterns[index], actuals[index], parameters, substitutions, span);
		switch pattern {
			case TTypeParameter(_, name) if (parameters.indexOf(name) >= 0):
				bindTypeParameter(name, actual, substitutions, span);
			case TNullable(element):
				switch actual {
					case TNullable(actualElement): inferFromType(element, actualElement, parameters, substitutions,
						span);
					default: inferFromType(element, actual, parameters, substitutions, span);
				}
			case TArray(element):
				switch actual {
					case TArray(actualElement): inferFromType(element, actualElement, parameters, substitutions, span);
					default:
				}
			case TIterator(element):
				switch actual {
					case TIterator(actualElement): inferFromType(element, actualElement, parameters, substitutions,
						span);
					default:
				}
			case TMap(key, value):
				switch actual {
					case TMap(actualKey, actualValue):
						inferFromType(key, actualKey, parameters, substitutions, span);
						inferFromType(value, actualValue, parameters, substitutions, span);
					default:
				}
			case TFunction(patternArguments, patternResult, _):
				switch actual {
					case TFunction(actualArguments, actualResult, _):
						each(patternArguments, actualArguments);
						inferFromType(patternResult, actualResult, parameters, substitutions, span);
					default:
				}
			case TInstance(_, name, patternArguments):
				var projected = session.declarations.inheritance.project(actual, name);
				switch projected == null ? actual : projected {
					case TInstance(_, actualName, actualArguments) if (actualName == name): each(patternArguments,
						actualArguments);
					default:
				}
			case TAbstract(name, patternArguments, _):
				switch actual {
					case TAbstract(actualName, actualArguments, _) if (actualName == name): each(patternArguments,
						actualArguments);
					default:
				}
			default:
		}
	}

	function bindTypeParameter(name:String, actual:CompilerType, substitutions:Map<String, CompilerType>,
			span:SourceSpan):Void {
		if (substitutions.exists(name)) {
			var previous = requiredMapValue(substitutions, name);
			// A type variable meets the type inferred before, as Haxe unifies them: `Lambda.concat([1], [])` fills the element of `[]`
			// with Int, and `Lambda.concat([], [2])` the first one's.
			if (Monomorphs.containsUnbound(previous) || Monomorphs.containsUnbound(actual)) {
				Monomorphs.unify(actual, previous);
				previous = Monomorphs.resolve(previous);
				actual = Monomorphs.resolve(actual);
				substitutions.set(name, previous);
			}
			if ((switch (previous) {
				case TDynamic: true;
				default: false;
			}))
				substitutions.set(name, actual);
			else if ((switch (actual) {
				case TDynamic: false;
				default: true;
			}) && !TypeRelations.equals(previous, actual)) {
				if (session.relations.isAssignable(actual, previous))
					substitutions.set(name, actual);
				else if (!session.relations.isAssignable(previous, actual))
					fail("E1003", 'Conflicting types inferred for generic parameter "$name"', span);
			}
		} else
			substitutions.set(name, actual);
	}

	public function inferTypeParameters(pattern:AstType, actual:CompilerType, parameters:Array<String>,
			substitutions:Map<String, CompilerType>,
			span:SourceSpan):Void
		switch pattern {
			case NamedType(name) if (parameters.indexOf(name) >= 0):
				bindTypeParameter(name, actual, substitutions, span);
			case ArrayType(element):
				switch actual {
					case TArray(actualElement): inferTypeParameters(element, actualElement, parameters, substitutions,
						span);
					default:
				}
			case MapType(key, value):
				switch actual {
					case TMap(actualKey, actualValue):
						inferTypeParameters(key, actualKey, parameters, substitutions, span);
						inferTypeParameters(value, actualValue, parameters, substitutions, span);
					default:
				}
			case NullableType(element):
				// `Null<T>` takes a value that is not nullable too, binding `T` to its type, as `inferFromType` does and Haxe unifies.
				switch actual {
					case TNullable(actualElement): inferTypeParameters(element, actualElement, parameters,
						substitutions, span);
					default: inferTypeParameters(element, actual, parameters, substitutions, span);
				}
			case AppliedType(name, patternArguments):
				// A rest parameter's arguments arrive packed in an array (`RestArguments`): its element fixes the type's.
				if (name == "haxe.Rest" && patternArguments.length == 1)
					switch actual {
						case TArray(actualElement):
							inferTypeParameters(patternArguments[0], actualElement, parameters, substitutions, span);
						default:
					}
				if ((name == "Iterable" || name == "Iterator") && patternArguments.length == 1) {
					var element = IterationProtocol.element(session.declarations, actual, name == "Iterable");
					if (element != null)
						inferTypeParameters(patternArguments[0], element, parameters, substitutions, span);
				}
				var projected = session.declarations.inheritance.project(actual, name);
				if (projected != null)
					actual = projected;
				switch actual {
					case TKeyPath(root, value,
						_) if ((name == "KeyPath" || name == "WritableKeyPath") && patternArguments.length == 2):
						inferTypeParameters(patternArguments[0], root, parameters, substitutions, span);
						inferTypeParameters(patternArguments[1], value, parameters, substitutions, span);
					case TIterator(actualElement) if (name == "Iterator" && patternArguments.length == 1):
						inferTypeParameters(patternArguments[0], actualElement, parameters, substitutions, span);
					case TInstance(_, actualName, actualArguments) if (actualName == name
						&& patternArguments.length == actualArguments.length):
						for (index in 0...patternArguments.length)
							inferTypeParameters(patternArguments[index], actualArguments[index], parameters,
								substitutions, span);
					case TAbstract(actualName, actualArguments, _) if (actualName == name
						&& patternArguments.length == actualArguments.length):
						for (index in 0...patternArguments.length)
							inferTypeParameters(patternArguments[index], actualArguments[index], parameters,
								substitutions, span);
					default:
				}
			case FunctionType(patternArguments, patternResult, _):
				switch actual {
					case TFunction(actualArguments,
						actualResult, _) if (patternArguments.length == actualArguments.length):
						for (i in 0...patternArguments.length)
							inferTypeParameters(patternArguments[i], actualArguments[i], parameters, substitutions,
								span);
						inferTypeParameters(patternResult, actualResult, parameters, substitutions, span);
					default:
				}
			case AnonymousType(patternFields):
				switch actual {
					case TAnonymous(_, actualFields):
						for (field in patternFields) {
							var actualField = anonymousField(actualFields, field.name);
							if (actualField != null)
								inferTypeParameters(field.type, actualField.type, parameters, substitutions, span);
						}
					default:
				}
			default:
		}

	function abstractReceiverType(name:String, substitutions:Map<String, CompilerType>):CompilerType {
		var decl = requiredMapValue(session.declarations.abstracts, name),
			arguments = [
				for (parameter in decl.typeParameters)
					requiredMapValue(substitutions, parameter)
			],
			representation = session.representation.semanticType(decl.underlying, decl.span, substitutions);
		return TAbstract(name, arguments, representation);
	}

	static function anonymousField(fields:Null<Array<compiler.types.Type.AnonymousField>>,
			name:String):Null<compiler.types.Type.AnonymousField> {
		if (fields != null)
			for (field in fields)
				if (field.name == name)
					return field;
		return null;
	}

	static function functionTypeParameters(fn:AstFunction):Array<String>
		return fn.typeParameters == null ? [] : fn.typeParameters;

	static function requiredMapValue<T>(source:Map<String, T>, name:String):T {
		if (!source.exists(name))
			throw new InternalError('Missing map entry "$name"');
		return source.get(name);
	}

	static function requiredString(value:Null<String>):String {
		if (value == null)
			throw new InternalError("Expected string");
		return value;
	}

	@:noReturn
	static function fail(code:String, message:String, span:SourceSpan):Void
		throw new CompileError(new Diagnostic(code, message, span));
}
