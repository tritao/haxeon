package compiler.types.typing;

import compiler.Diagnostic;
import compiler.Diagnostic.CompileError;
import compiler.Source.SourceSpan;
import compiler.runtime.PlatformAbi;
import compiler.semantic.GenericSpecializationPolicy;
import compiler.syntax.Ast.AstArgument;
import compiler.syntax.Ast.AstEnum;
import compiler.syntax.Ast.AstEnumParameter;
import compiler.syntax.Ast.AstFunction;
import compiler.syntax.Ast.AstType;
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

/** Complete semantic and physical contract for one generic function call. */
typedef GenericCallRepresentationResult = {
	final representation:GenericRepresentationResult;
	final argumentTypes:Array<CompilerType>;
	final arguments:Array<TypedExpression>;
	final result:TypeRepresentationResult;
	final typeArguments:Array<CompilerType>;
};

typedef GenericArgumentTypeResolver = (AstArgument, Null<Map<String, CompilerType>>) -> CompilerType;

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
	final session:TypingSession;

	public function new(session:TypingSession)
		this.session = session;

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
		]);
	}

	/** Adapt constructor arguments, including constructors without a declaration. */
	public function adaptConstructorArguments(receiver:CompilerType, owner:String, method:Null<AstFunction>,
			arguments:Array<TypedExpression>):Array<TypedExpression> {
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
				decision = GenericSpecializationPolicy.decide(fn, parameter, semantic);
			substitutions.set(parameter, decision.representation);
			policies.push(decision.policy);
		}
		return {substitutions: substitutions, policies: policies};
	}

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
	public function boundaryCast(value:TypedExpression, target:CompilerType):TypedExpression
		return TypeRelations.equals(value.type, target) ? value : new TypedExpression(TAbiCast(value), target, value.span, value.stableFlowValue);

	/** Resolve a class/interface field with both semantic and physical types. */
	public function resolveField(type:CompilerType, name:String, span:SourceSpan):TypeRepresentationResult {
		var semantic = fieldType(type, name, span),
			physical = physicalFieldType(type, name, span);
		return {semantic: semantic, physical: physical};
	}

	/** Physical storage type for an enum constructor payload. */
	public function enumStorageType(typeParameters:Array<String>, parameter:AstEnumParameter):CompilerType {
		// Generic enums publish one shared constructor layout. Payloads must not
		// vary by source specialization, including concrete-looking payloads.
		if (typeParameters.length > 0)
			return TDynamic;
		return physicalType(parameter.type, parameter.span, []);
	}

	public function erasedEnumParameter(declaration:AstEnum, parameter:AstEnumParameter):CompilerType
		return enumStorageType(declaration.typeParameters, parameter);

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
			physical = isGenericNominal(projected) ? erasedNominalSubstitutions(owner) : copyMap(semantic);
		return {semantic: semantic, physical: physical};
	}

	public function isGenericNominal(type:CompilerType):Bool
		return switch type {
			case TInstance(Class, _, arguments), TInstance(Interface, _, arguments): arguments.length > 0;
			default: false;
		};

	function adaptArguments(arguments:Array<TypedExpression>, expected:Array<CompilerType>):Array<TypedExpression> {
		return [
			for (index in 0...arguments.length)
				boundaryCast(arguments[index], expected[index])
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
		if (argument.optional == true && argument.defaultValue == null) {
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
					substitutions = erasedNominalSubstitutions(className),
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
