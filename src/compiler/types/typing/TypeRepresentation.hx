package compiler.types.typing;

import compiler.Diagnostic;
import compiler.Diagnostic.CompileError;
import compiler.Source.SourceSpan;
import compiler.ffi.NativeLayout;
import compiler.runtime.PlatformAbi;
import compiler.runtime.RuntimeType;
import compiler.semantic.GenericSpecializationPolicy;
import compiler.semantic.SemanticSignature;
import compiler.syntax.Ast.AstArgument;
import compiler.syntax.Ast.AstClass;
import compiler.syntax.Ast.AstEnum;
import compiler.syntax.Ast.AstEnumParameter;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstFunction;
import compiler.syntax.Ast.AstType;
import compiler.syntax.AstPredicates;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypeRelations;

/** Semantic and physical types for one ABI-sensitive operation. */
typedef TypeRepresentationResult = {
	final semantic:CompilerType;
	final physical:CompilerType;
};

/** Generic substitutions selected for a shared generic function body. */
typedef GenericRepresentationResult = {
	final substitutions:Map<String, CompilerType>;
	final policies:Array<String>;
};

/** One concrete physical owner and the substitutions used to type its instance members. */
typedef GenericOwnerRepresentation = {
	final origin:String;
	final name:String;
	final typeArguments:Array<CompilerType>;
	final substitutions:Map<String, CompilerType>;
	final policies:Array<String>;
};

/** Complete semantic and physical contract for one generic function call. */
typedef GenericCallRepresentationResult = {
	final representation:GenericRepresentationResult;
	final argumentTypes:Array<CompilerType>;
	final arguments:Array<TypedExpression>;
	final result:TypeRepresentationResult;
	final typeArguments:Array<CompilerType>;
};

typedef GenericArgumentTypeResolver = (AstArgument, Null<Map<String, CompilerType>>) -> CompilerType;

typedef ScalarMapRecordPair = {
	final semantic:Array<compiler.types.Type.AnonymousField>;
	final physical:Array<compiler.types.Type.AnonymousField>;
};

/**
 * Owns the boundary between source-level types and emitted representations.
 *
 * A semantic type describes what Haxe code means. A physical type describes
 * the type published by the emitted body at an ABI boundary. They are often
 * equal, but generic class and interface owners erase their own parameters
 * in shared bodies. Keeping both values here prevents individual typing
 * paths from making independent Dynamic decisions.
 */
class TypeRepresentation {
	/** Bound polymorphic owner recursion before it can exhaust the compiler. */
	static inline var MAX_OWNER_TYPE_DEPTH:Int = 64;
	static inline var MAX_OWNER_TYPE_NODES:Int = 4096;
	final session:TypingSession;
	final enumBodyUses:Map<String, Bool> = [];
	final conversions:ConversionResolver;
	final ownerRequests:Map<String, GenericOwnerRepresentation> = [];
	final requestedOwners:Array<GenericOwnerRepresentation> = [];
	final ownerAliases:Map<String, String> = [];

	public function new(session:TypingSession) {
		this.session = session;
		conversions = new ConversionResolver(session);
	}

	public function semanticType(type:AstType, ?span:SourceSpan, ?substitutions:Map<String, CompilerType>):CompilerType
		return session.declarations.resolve(type, span, substitutions);

	public function physicalType(type:AstType, ?span:SourceSpan, ?substitutions:Map<String, CompilerType>):CompilerType
		return semanticType(type, span, substitutions);

	/** Resolve a method result through the receiver's nominal projection. */
	public function resolveMethodResult(receiver:CompilerType, owner:String, method:AstFunction):TypeRepresentationResult
		return resolve(method.result, method.span, methodSubstitutions(receiver, owner));

	/** Resolve all method parameters through the receiver's nominal projection. */
	public function resolveMethodArguments(receiver:CompilerType, owner:String, method:AstFunction):Array<TypeRepresentationResult> {
		var substitutions = methodSubstitutions(receiver, owner),
			result:Array<TypeRepresentationResult> = [];
		for (argument in method.arguments)
			result.push(resolveArgument(argument, substitutions));
		return result;
	}

	/** Resolve one method parameter through the receiver's nominal projection. */
	public function resolveMethodArgument(receiver:CompilerType, owner:String, argument:AstArgument):TypeRepresentationResult
		return resolveArgument(argument, methodSubstitutions(receiver, owner));

	/** Adapt semantic call arguments to the physical method signature. */
	public function adaptMethodArguments(receiver:CompilerType, owner:String, method:AstFunction, arguments:Array<TypedExpression>):Array<TypedExpression> {
		return adaptArguments(arguments, [
			for (representation in resolveMethodArguments(receiver, owner, method))
				representation.physical
		], receiver);
	}

	/** Adapt constructor arguments, including constructors without a declaration. */
	public function adaptConstructorArguments(receiver:CompilerType, owner:String, method:Null<AstFunction>,
			arguments:Array<TypedExpression>):Array<TypedExpression> {
		genericOwner(receiver);
		if (method != null)
			return adaptMethodArguments(receiver, owner, method, arguments);
		return isGenericNominal(receiver) ? [for (argument in arguments) boundaryCast(argument, TDynamic)] : arguments;
	}

	/** Build substitutions for a declaration when an omitted argument is erased. */
	public function typeParameterSubstitutions(parameters:Array<String>, arguments:Array<CompilerType>):Map<String, CompilerType> {
		var result:Map<String, CompilerType> = [];
		for (index in 0...parameters.length)
			result.set(parameters[index], index < arguments.length ? arguments[index] : TDynamic);
		return result;
	}

	/** Resolve an enum payload through the use-site instance. */
	public function enumParameterType(typeParameters:Array<String>, parameter:AstEnumParameter, instance:Null<CompilerType>):CompilerType {
		var arguments = switch enumInstance(instance) {
			case TInstance(Enum, _, values): values;
			default: [];
		};
		var substitutions = typeParameterSubstitutions(typeParameters, arguments),
			resolved = semanticType(parameter.type, parameter.span, substitutions);
		return parameter.optional ? TNullable(resolved) : resolved;
	}

	/** Build the receiver type used while typing a generic class body. */
	public function receiverType(owner:String, substitutions:Map<String, CompilerType>):CompilerType {
		var arguments:Array<CompilerType> = [],
			declaration = session.classDecls.get(owner);
		if (declaration != null)
			for (parameter in declaration.typeParameters)
				arguments.push(substitutions != null && substitutions.exists(parameter) ? substitutions.get(parameter) : TDynamic);
		return TInstance(NominalKind.Class, owner, arguments);
	}

	/**
	 * Select the physical substitutions for a generic function body. This is
	 * the only typing service entry point that applies shape specialization.
	 */
	public function genericFunction(fn:AstFunction, semanticSubstitutions:Map<String, CompilerType>):GenericRepresentationResult {
		var substitutions = copyMap(semanticSubstitutions),
			policies:Array<String> = [];
		for (parameter in functionTypeParameters(fn)) {
			var semantic = requiredMapValue(semanticSubstitutions, parameter),
				decision = GenericSpecializationPolicy.decide(fn, parameter, semantic, type -> requiresLayoutSpecialization(type)
					|| functionUsesGenericEnum(fn, parameter));
			substitutions.set(parameter, decision.representation);
			policies.push(decision.policy);
		}
		return {substitutions: substitutions, policies: policies};
	}

	function functionUsesGenericEnum(fn:AstFunction, parameter:String):Bool {
		var key = fn.span.file.path + ":" + fn.span.start + ":" + fn.name + ":" + parameter;
		if (!enumBodyUses.exists(key)) enumBodyUses.set(key, compiler.types.analysis.GenericEnumUsage.uses(fn,
			type -> enumContainsParameter(type, parameter, [])));
		return enumBodyUses.get(key);
	}

	/**
	 * Discover the physical owner for a class instance with a value or constrained argument.
	 * The queue belongs to this typing session, independently of the persistent naming
	 * registry: a known name still needs its body emitted in a fresh compilation.
	 */
	public function genericOwner(type:CompilerType):Null<GenericOwnerRepresentation> {
		var name:String, arguments:Array<CompilerType>;
		switch type {
			case TInstance(NominalKind.Class, owner, values): name = owner; arguments = values;
			default: return null;
		}
		var declaration = session.classDecls.get(name);
		if (declaration == null || declaration.typeParameters.length == 0 || arguments.length != declaration.typeParameters.length)
			return null;
		var needsSpecialization = declaration.typeConstraints != null && declaration.typeConstraints.length > 0;
		if (declaration.typeConstraints != null)
			for (constraint in declaration.typeConstraints) {
				var index = declaration.typeParameters.indexOf(constraint.parameter);
				if (index >= 0 && (switch (arguments[index]) { case TDynamic: true; default: false; })) return null;
			}
		for (index in 0...arguments.length) {
			var argument = arguments[index];
			if (containsTypeParameter(argument, [])) return null;
			// A generic implementation of a generic interface must retain scalar carriers in
			// its physical methods. Follow inherited interfaces as well as direct ones.
			if (switch argument { case TInt | TInt64 | TFloat | TBool: true; default: false; })
				for (interfaceType in session.declarations.inheritance.inheritedInterfaces(type))
					switch interfaceType {
						case TInstance(Interface, _, parameters):
							for (parameter in parameters) if (TypeRelations.equals(argument, parameter)) needsSpecialization = true;
						default:
					}
			if (ownerContainsValue(argument) || (switch argument { case TDynamic: false; default: ownerUsesGenericEnum(declaration, declaration.typeParameters[index]); }))
				needsSpecialization = true;
		}
		if (!needsSpecialization)
			return null;
		var substitutions:Map<String, CompilerType> = [], policies:Array<String> = [], representations:Array<CompilerType> = [];
		for (index in 0...arguments.length) {
			var parameter = declaration.typeParameters[index],
				decision = GenericSpecializationPolicy.decideOwner(declaration, parameter, arguments[index],
					type -> requiresLayoutSpecialization(type) || ownerUsesGenericEnum(declaration, parameter));
			substitutions.set(parameter, decision.representation);
			policies.push(decision.policy);
			representations.push(decision.representation);
		}
		validateOwnerComplexity(representations, name, declaration.span);
		var specialization = session.genericSpecializations.request('$' + 'owner:' + name, representations, policies),
			existing = ownerRequests.get(specialization.name);
		ownerAliases.set(SemanticSignature.type(type), specialization.name);
		if (existing != null)
			return existing;
		var result:GenericOwnerRepresentation = {
			origin: name,
			name: specialization.name,
			typeArguments: representations,
			substitutions: substitutions,
			policies: policies
		};
		ownerRequests.set(result.name, result);
		requestedOwners.push(result);
		return result;
	}

	static function validateOwnerComplexity(arguments:Array<CompilerType>, name:String, span:SourceSpan):Void {
		var remaining = [MAX_OWNER_TYPE_NODES];
		for (argument in arguments)
			if (exceedsOwnerComplexity(argument, 1, [], remaining))
				throw new CompileError(new Diagnostic("E1028", 'Generic owner "$name" exceeds the specialization type complexity limit ($MAX_OWNER_TYPE_DEPTH nesting levels or $MAX_OWNER_TYPE_NODES type nodes); check for polymorphic recursion', span));
	}

	/** Follow structural type arguments, stopping at recursive anonymous records. */
	static function exceedsOwnerComplexity(type:CompilerType, depth:Int, active:Array<Array<compiler.types.Type.AnonymousField>>, remaining:Array<Int>):Bool {
		remaining[0]--;
		if (depth > MAX_OWNER_TYPE_DEPTH || remaining[0] < 0) return true;
		return switch type {
			case TInstance(_, _, arguments): anyExceedsOwnerComplexity(arguments, depth + 1, active, remaining);
			case TAbstract(_, arguments, representation):
				anyExceedsOwnerComplexity(arguments, depth + 1, active, remaining) || exceedsOwnerComplexity(representation, depth + 1, active, remaining);
			case TNullable(inner), TArray(inner), TIterator(inner): exceedsOwnerComplexity(inner, depth + 1, active, remaining);
			case TMap(key, value): exceedsOwnerComplexity(key, depth + 1, active, remaining) || exceedsOwnerComplexity(value, depth + 1, active, remaining);
			case TKeyPath(root, value, _): exceedsOwnerComplexity(root, depth + 1, active, remaining) || exceedsOwnerComplexity(value, depth + 1, active, remaining);
			case TFunction(arguments, result):
				anyExceedsOwnerComplexity(arguments, depth + 1, active, remaining) || exceedsOwnerComplexity(result, depth + 1, active, remaining);
			case TAnonymous(_, fields):
				if (active.indexOf(fields) >= 0) false else {
					active.push(fields);
					var exceeded = false;
					for (field in fields) if (exceedsOwnerComplexity(field.type, depth + 1, active, remaining)) { exceeded = true; break; }
					active.pop();
					exceeded;
				}
			default: false;
		};
	}

	static function anyExceedsOwnerComplexity(types:Array<CompilerType>, depth:Int, active:Array<Array<compiler.types.Type.AnonymousField>>, remaining:Array<Int>):Bool {
		for (type in types) if (exceedsOwnerComplexity(type, depth, active, remaining)) return true;
		return false;
	}

	/** Requests can grow as specialized member bodies are typed; callers drain to a fixed point. */
	public function genericOwnerRequestCount():Int
		return requestedOwners.length;

	public function genericOwnerRequest(index:Int):GenericOwnerRepresentation
		return requestedOwners[index];

	public function genericOwnerAliases():Map<String, String> {
		var result:Map<String, String> = [];
		for (signature => name in ownerAliases) result.set(signature, name);
		return result;
	}

	/** Whether every class, enum and interface named in `types` is declared, so a specialization of them can still be made. */
	public function typeNamesExist(types:Array<CompilerType>):Bool {
		for (type in types)
			switch type {
				case TInstance(kind, name, arguments):
					var declared = switch kind {
						case NominalKind.Class: session.classDecls.exists(name);
						case NominalKind.Enum: session.enumDecls.exists(name);
						case NominalKind.Interface: session.interfaceDecls.exists(name);
						default: true;
					};
					if (!declared || !typeNamesExist(arguments))
						return false;
				case TNullable(element), TArray(element), TIterator(element):
					if (!typeNamesExist([element]))
						return false;
				case TMap(key, value):
					if (!typeNamesExist([key, value]))
						return false;
				case TFunction(arguments, result):
					if (!typeNamesExist(arguments) || !typeNamesExist([result]))
						return false;
				default:
			}
		return true;
	}

	/** Preserve aliases referenced by unchanged cached callers during incremental typing. */
	public function restoreGenericOwnerAliases(previous:Map<String, String>, retained:Map<String, Bool>):Void
		for (signature => name in previous) if (retained.exists(name)) ownerAliases.set(signature, name);

	/** Record the typer's selected map representation under the source Map type as well as its generic owner. */
	public function specializedMapOwner(key:CompilerType, value:CompilerType):Void {
		var owner = genericOwner(TInstance(NominalKind.Class, RuntimeType.SPECIALIZED_MAP, [session.specializedMapKey(key), value]));
		if (owner != null) ownerAliases.set(SemanticSignature.type(TMap(key, value)), owner.name);
	}

	/** Discover owners inside signatures and storage types, including recursive anonymous types. */
	public function discoverGenericOwners(type:CompilerType, ?origin:String):Void
		discoverOwners(type, [], origin);

	function discoverOwners(type:CompilerType, explored:Array<Array<compiler.types.Type.AnonymousField>>, origin:Null<String>):Void {
		switch type {
			case TInstance(_, _, arguments):
				genericOwner(type);
				for (argument in arguments) discoverOwners(argument, explored, origin);
			case TAbstract(_, arguments, representation):
				for (argument in arguments) discoverOwners(argument, explored, origin);
				discoverOwners(representation, explored, origin);
			case TNullable(inner), TArray(inner), TIterator(inner): discoverOwners(inner, explored, origin);
			case TMap(key, value):
				if (session.requiresSpecializedMap(key, value)) {
					if (origin != null) session.runtimeDependencyTracker.record(origin, RuntimeType.SPECIALIZED_MAP);
					specializedMapOwner(key, value);
				}
				discoverOwners(key, explored, origin); discoverOwners(value, explored, origin);
			case TKeyPath(root, value, _): discoverOwners(root, explored, origin); discoverOwners(value, explored, origin);
			case TFunction(arguments, result):
				for (argument in arguments) discoverOwners(argument, explored, origin);
				discoverOwners(result, explored, origin);
			case TAnonymous(_, fields):
				if (explored.indexOf(fields) < 0) {
					explored.push(fields);
					for (field in fields) discoverOwners(field.type, explored, origin);
				}
			default:
		}
	}

	public function containsTypeParameter(type:CompilerType, explored:Array<Array<compiler.types.Type.AnonymousField>>):Bool
		return switch type {
			case TTypeParameter(_, _): true;
			case TInstance(_, _, arguments): anyTypeParameter(arguments, explored);
			case TAbstract(_, arguments, representation): anyTypeParameter(arguments, explored) || containsTypeParameter(representation, explored);
			case TNullable(inner), TArray(inner), TIterator(inner): containsTypeParameter(inner, explored);
			case TMap(key, value): containsTypeParameter(key, explored) || containsTypeParameter(value, explored);
			case TKeyPath(root, value, _): containsTypeParameter(root, explored) || containsTypeParameter(value, explored);
			case TFunction(arguments, result): anyTypeParameter(arguments, explored) || containsTypeParameter(result, explored);
			case TAnonymous(_, fields):
				var found = false;
				if (explored.indexOf(fields) < 0) {
					explored.push(fields);
					for (field in fields)
						if (containsTypeParameter(field.type, explored)) found = true;
				}
				found;
			default: false;
		};

	function anyTypeParameter(types:Array<CompilerType>, explored:Array<Array<compiler.types.Type.AnonymousField>>):Bool {
		for (type in types)
			if (containsTypeParameter(type, explored)) return true;
		return false;
	}

	/** A boxed generic enum needs its concrete descriptor throughout an owner's ABI. */
	function ownerUsesGenericEnum(owner:AstClass, parameter:String, ?seen:Array<String>):Bool {
		if (seen == null) seen = [];
		var key = owner.name + ":" + parameter;
		if (seen.indexOf(key) >= 0) return false;
		seen.push(key);
		var found = owner.base != null && enumContainsParameter(owner.base, parameter, seen);
		for (contract in owner.interfaces) if (enumContainsParameter(contract, parameter, seen)) found = true;
		for (field in owner.fields) if (!field.isStatic && field.type != null && enumContainsParameter(field.type, parameter, seen)) found = true;
		for (method in owner.methods) {
			if (method.isStatic || method.typeParameters != null && method.typeParameters.indexOf(parameter) >= 0) continue;
			for (argument in method.arguments) if (enumContainsParameter(argument.type, parameter, seen)) found = true;
			if (enumContainsParameter(method.result, parameter, seen)) found = true;
			if (!found && compiler.types.analysis.GenericEnumUsage.uses(method, type -> enumContainsParameter(type, parameter, seen))) found = true;
		}
		seen.pop();
		return found;
	}

	function enumContainsParameter(type:AstType, parameter:String, seen:Array<String>):Bool return switch type {
		case AppliedType(name, arguments):
			var found = false, alias = session.declarations.aliases.get(name), owner = session.classDecls.get(name);
			if (session.enumDecls.exists(name)) for (argument in arguments) if (containsSyntaxParameter(argument, parameter)) found = true;
			if (alias != null) {
				var key = "alias:" + name;
				if (seen.indexOf(key) < 0) {
					seen.push(key);
					for (index in 0...arguments.length)
						if (index < alias.typeParameters.length && containsSyntaxParameter(arguments[index], parameter)
							&& enumContainsParameter(alias.type, alias.typeParameters[index], seen)) found = true;
					seen.pop();
				}
			}
			if (owner != null) for (index in 0...arguments.length)
				if (index < owner.typeParameters.length && containsSyntaxParameter(arguments[index], parameter)
					&& ownerUsesGenericEnum(owner, owner.typeParameters[index], seen)) found = true;
			for (argument in arguments) if (enumContainsParameter(argument, parameter, seen)) found = true;
			found;
		case ArrayType(element), NullableType(element): enumContainsParameter(element, parameter, seen);
		case MapType(key, value): enumContainsParameter(key, parameter, seen) || enumContainsParameter(value, parameter, seen);
		case FunctionType(arguments, result):
			var found = enumContainsParameter(result, parameter, seen);
			for (argument in arguments) if (enumContainsParameter(argument, parameter, seen)) found = true;
			found;
		case AnonymousType(fields):
			var found = false;
			for (field in fields) if (enumContainsParameter(field.type, parameter, seen)) found = true;
			found;
		default: false;
	};

	static function containsSyntaxParameter(type:AstType, parameter:String):Bool return switch type {
		case NamedType(name): name == parameter;
		case AppliedType(_, arguments):
			var found = false;
			for (argument in arguments) if (containsSyntaxParameter(argument, parameter)) found = true;
			found;
		case ArrayType(element), NullableType(element): containsSyntaxParameter(element, parameter);
		case MapType(key, value): containsSyntaxParameter(key, parameter) || containsSyntaxParameter(value, parameter);
		case FunctionType(arguments, result):
			var found = containsSyntaxParameter(result, parameter);
			for (argument in arguments) if (containsSyntaxParameter(argument, parameter)) found = true;
			found;
		case AnonymousType(fields):
			var found = false;
			for (field in fields) if (containsSyntaxParameter(field.type, parameter)) found = true;
			found;
		default: false;
	};

	/** Reference containers already own their element representation; they do not put it in this owner. */
	function ownerContainsValue(type:CompilerType):Bool
		return switch type {
			case TAbstract(_, _, representation), TNullable(representation): ownerContainsValue(representation);
			case TInstance(NominalKind.Class, _, _): session.relations.isValueClass(type);
			case TInstance(NominalKind.Enum, _, _), TInstance(NominalKind.NativeValue, _, _), TNativeScalar(_), THlBytes: true;
			default: false;
		};

	/** Value types need their exact storage and calling convention, including managed structs without a native layout. */
	function requiresLayoutSpecialization(type:CompilerType):Bool
		return NativeLayout.containsNativeLayoutType(type) || containsExactValueLayout(type, null);

	function containsExactValueLayout(type:CompilerType, explored:Null<Array<Array<compiler.types.Type.AnonymousField>>>):Bool
		return switch type {
			case THlBytes: true; // A raw pointer is a scalar carrier, not a shared managed reference.
			case TInstance(NominalKind.Class, name, _) if (session.nativeLayoutsByName.exists(name) || session.relations.isValueClass(type)): true;
			case TInstance(NominalKind.Enum, _, _): true;
			case TAbstract(_, _, representation), TNullable(representation), TArray(representation), TIterator(representation):
				containsExactValueLayout(representation, explored);
			case TMap(key, value): containsExactValueLayout(key, explored) || containsExactValueLayout(value, explored);
			case TKeyPath(_, _, _): true;
			case TFunction(arguments, result):
				var found = containsExactValueLayout(result, explored);
				for (argument in arguments)
					if (containsExactValueLayout(argument, explored))
						found = true;
				found;
			case TAnonymous(_, fields):
				var walked = explored == null ? [] : explored, found = false;
				if (walked.indexOf(fields) < 0) {
					walked.push(fields);
					for (field in fields)
						if (containsExactValueLayout(field.type, walked))
							found = true;
				}
				found;
			case _: false;
		};

	/** Resolve and adapt one generic call across its shared-body ABI boundary. */
	public function resolveGenericCall(fn:AstFunction, semanticSubstitutions:Map<String, CompilerType>, arguments:Array<TypedExpression>,
			argumentType:GenericArgumentTypeResolver):GenericCallRepresentationResult {
		var representation = genericFunction(fn, semanticSubstitutions),
			argumentTypes = [
				for (argument in fn.arguments)
					argumentType(argument, representation.substitutions)
			],
			result:TypeRepresentationResult = {
				semantic: semanticType(fn.result, fn.span, semanticSubstitutions),
				physical: physicalType(fn.result, fn.span, representation.substitutions)
			};
		return {
			representation: representation,
			argumentTypes: argumentTypes,
			arguments: adaptArguments(arguments, argumentTypes),
			result: result,
			typeArguments: [
				for (parameter in functionTypeParameters(fn))
					requiredMapValue(representation.substitutions, parameter)
			]
		};
	}

	/** Substitutions used by a shared body owned by a generic class/interface. */
	public function erasedNominalSubstitutions(owner:String):Map<String, CompilerType> {
		var result:Map<String, CompilerType> = [];
		var classDecl = session.classDecls.get(owner);
		if (classDecl != null)
			for (parameter in classDecl.typeParameters)
				result.set(parameter, TDynamic);
		var interfaceDecl = session.interfaceDecls.get(owner);
		if (interfaceDecl != null)
			for (parameter in interfaceDecl.typeParameters)
				result.set(parameter, TDynamic);
		return result;
	}

	/** Apply the ABI cast required to cross from a physical to semantic type. */
	public function boundaryCast(value:TypedExpression, target:CompilerType, ?owner:CompilerType):TypedExpression {
		if (TypeRelations.equals(value.type, target))
			return value;
		rejectMapStorageChange(value, target, owner);
		if (ConversionResolver.functionSignaturesDiffer(value.type, target))
			return conversions.adaptFunction(value, target, value.span);
		return new TypedExpression(TAbiCast(value), target, value.span, value.stableFlowValue);
	}

	/** a2 removes this diagnostic when erased map ABI crossings retain their storage kind. */
	function rejectMapStorageChange(value:TypedExpression, target:CompilerType, owner:Null<CompilerType>):Void {
		if (isNullMapValue(value)) return;
		if (hasMapStorageChange(mapBoundaryType(value.type), mapBoundaryType(target), [])) {
			var context = owner == null ? "Generic map boundary" : 'Type "${SemanticSignature.display(owner)}"';
			throw new CompileError(new Diagnostic("E1009",
				'$context: scalar map values in unspecialized generic owners are not supported yet at a storage-changing boundary (${SemanticSignature.display(value.type)} to ${SemanticSignature.display(target)})', value.span));
		}
	}

	function mapStorageName(key:CompilerType, value:CompilerType):Null<String> {
		var name = session.mapName(key, value);
		return name == RuntimeType.SPECIALIZED_MAP ? ownerAliases.get(SemanticSignature.type(TMap(key, value))) : name;
	}

	static function mapBoundaryType(type:CompilerType):CompilerType
		return switch type {
			case TNullable(value), TAbstract(_, _, value): mapBoundaryType(value);
			default: type;
		};

	static function isNullMapValue(value:TypedExpression):Bool
		return switch value.expression {
			case TNullLiteral: true;
			case TAbiCast(inner): isNullMapValue(inner);
			default: false;
		};

	function hasMapStorageChange(actual:CompilerType, physical:CompilerType,
			seen:Array<ScalarMapRecordPair>):Bool {
		return switch actual {
			case TAbstract(_, _, representation):
				hasMapStorageChange(representation, switch physical { case TAbstract(_, _, value): value; default: physical; }, seen);
			case TMap(key, value): switch physical {
				case TMap(erasedKey, erasedValue):
					var storage = mapStorageName(key, value), erasedStorage = mapStorageName(erasedKey, erasedValue);
					(storage != null && erasedStorage != null && storage != erasedStorage)
						|| hasMapStorageChange(key, erasedKey, seen) || hasMapStorageChange(value, erasedValue, seen);
				default: false;
			};
			case TNullable(value), TArray(value), TIterator(value): switch physical {
				case TNullable(erasedValue), TArray(erasedValue), TIterator(erasedValue): hasMapStorageChange(value, erasedValue, seen);
				default: false;
			};
			case TInstance(_, _, values): switch physical {
				case TInstance(_, _, erasedValues): scalarMapArguments(values, erasedValues, seen);
				default: false;
			};
			case TFunction(values, result): switch physical {
				case TFunction(erasedValues, erasedResult): scalarMapArguments(values, erasedValues, seen) || hasMapStorageChange(result, erasedResult, seen);
				default: false;
			};
			case TKeyPath(root, value, _): switch physical {
				case TKeyPath(erasedRoot, erasedValue, _): hasMapStorageChange(root, erasedRoot, seen) || hasMapStorageChange(value, erasedValue, seen);
				default: false;
			};
			case TAnonymous(_, fields): switch physical {
				case TAnonymous(_, erasedFields) if (fields.length == erasedFields.length):
					var active = false;
					for (pair in seen) if (pair.semantic == fields && pair.physical == erasedFields) active = true;
					if (active) false else {
						seen.push({semantic: fields, physical: erasedFields});
						var found = false;
						for (index in 0...fields.length) if (hasMapStorageChange(fields[index].type, erasedFields[index].type, seen)) found = true;
						seen.pop();
						found;
					}
				default: false;
			};
			default: false;
		};
	}

	function scalarMapArguments(actual:Array<CompilerType>, physical:Array<CompilerType>,
			seen:Array<ScalarMapRecordPair>):Bool {
		if (actual.length != physical.length) return false;
		for (index in 0...actual.length) if (hasMapStorageChange(actual[index], physical[index], seen)) return true;
		return false;
	}

	/** Resolve a class/interface field with both semantic and physical types. */
	public function resolveField(type:CompilerType, name:String, span:SourceSpan):TypeRepresentationResult {
		var semantic = fieldType(type, name, span),
			physical = physicalFieldType(type, name, span);
		return {semantic: semantic, physical: physical};
	}

	/** Physical storage type for an enum constructor payload. */
	public function enumStorageType(typeParameters:Array<String>, parameter:AstEnumParameter, instance:CompilerType):CompilerType
		return session.enumRepresentations.storage(typeParameters, parameter, instance);

	/** Resolve an abstract's underlying representation without losing identity. */
	public function abstractUnderlying(type:CompilerType):CompilerType
		return switch type {
			case TAbstract(_, _, representation): representation;
			default: type;
		};

	public function nominalSubstitutions(type:CompilerType):Map<String, CompilerType>
		return session.declarations.inheritance.substitutions(type);

	public function methodSubstitutions(receiver:CompilerType, owner:String):{semantic:Map<String, CompilerType>, physical:Map<String, CompilerType>} {
		var projected = projectNominal(receiver, owner),
			semantic = nominalSubstitutions(projected),
			specialization = genericOwner(projected),
			typedInterface = switch projected { case TInstance(Interface, _, arguments) if (arguments.length > 0): true; default: false; },
			physical = specialization != null ? copyMap(specialization.substitutions)
				: typedInterface ? copyMap(semantic) : isGenericNominal(projected) ? erasedNominalSubstitutions(owner) : copyMap(semantic);
		return {semantic: semantic, physical: physical};
	}

	public function isGenericNominal(type:CompilerType):Bool
		return switch type {
			case TInstance(Class, _, arguments), TInstance(Interface, _, arguments): arguments.length > 0;
			default: false;
		};

	function adaptArguments(arguments:Array<TypedExpression>, expected:Array<CompilerType>, ?owner:CompilerType):Array<TypedExpression> {
		return [
			for (index in 0...arguments.length)
				boundaryCast(arguments[index], expected[index], owner)
		];
	}

	function enumInstance(type:Null<CompilerType>):Null<CompilerType>
		return switch type {
			case TInstance(Enum, _, _): type;
			case TNullable(inner), TAbstract(_, _, inner): enumInstance(inner);
			default: null;
		};

	function resolve(type:AstType, span:SourceSpan,
			substitutions:{semantic:Map<String, CompilerType>, physical:Map<String, CompilerType>}):TypeRepresentationResult
		return {
			semantic: semanticType(type, span, substitutions.semantic),
			physical: physicalType(type, span, substitutions.physical)
		};

	function resolveArgument(argument:AstArgument,
			substitutions:{semantic:Map<String, CompilerType>, physical:Map<String, CompilerType>}):TypeRepresentationResult {
		var result = resolve(argument.type, argument.span, substitutions);
		var alreadyNullable = switch result.semantic {
			case TNullable(_): true;
			default: false;
		};
		if (argument.optional == true && AstPredicates.isNullExpression(argument.defaultValue) && !alreadyNullable) {
			result = {
				semantic: TNullable(result.semantic),
				physical: TNullable(result.physical)
			};
		}
		return result;
	}

	function fieldType(type:CompilerType, name:String, span:SourceSpan):CompilerType {
		var platformField = PlatformAbi.field(type, name);
		if (platformField != null)
			return platformField.type;
		switch type {
			case TAnonymous(_, fields):
				for (field in fields)
					if (field.name == name)
						return field.type;
				throw new CompileError(new Diagnostic("E1005", 'Unknown anonymous field "$name"', span));
			case TInstance(Class, className, _):
				var declaration = session.classDecls.get(className);
				if (declaration != null) {
					for (field in declaration.fields)
						if (field.name == name && !field.isStatic)
							return session.declarations.resolve(session.declarations.resolvedFieldType(className, field), field.span,
								nominalSubstitutions(type));
					if (declaration.base != null)
						return fieldType(session.declarations.resolve(declaration.base, declaration.span, nominalSubstitutions(type)), name, span);
				}
				throw new CompileError(new Diagnostic("E1005", 'Unknown field "$className.$name"', span));
			default:
				throw new CompileError(new Diagnostic("E1005", 'Field "$name" requires an object', span));
		}
	}

	function physicalFieldType(type:CompilerType, name:String, span:SourceSpan):CompilerType
		return switch type {
			case TInstance(Class, className, _) if (session.classDecls.exists(className)):
				var declaration = requiredMapValue(session.classDecls, className),
					specialization = genericOwner(type),
					substitutions = specialization == null ? erasedNominalSubstitutions(className) : specialization.substitutions,
					result:Null<CompilerType> = null;
				for (field in declaration.fields)
					if (field.name == name && !field.isStatic)
						result = physicalType(session.declarations.resolvedFieldType(className, field), field.span, substitutions);
				if (result != null) result; else if (declaration.base != null) physicalFieldType(session.declarations.resolve(declaration.base,
					declaration.span, substitutions), name, span); else fieldType(type, name, span);
			default:
				fieldType(type, name, span);
		};

	function projectNominal(type:CompilerType, target:String):CompilerType {
		var projected = session.declarations.inheritance.project(type, target);
		return projected == null ? type : projected;
	}

	static function functionTypeParameters(fn:AstFunction):Array<String>
		return fn.typeParameters == null ? [] : fn.typeParameters;

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
}
