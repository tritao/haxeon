package compiler.types.typing;

import compiler.core.InternalError;
import compiler.core.Provides;
import compiler.core.Provides.ProviderOperation;
import compiler.core.Provides.ProviderOperations;
import compiler.core.Source.SourceSpan;
import compiler.core.TextDigest;
import compiler.syntax.Ast.AstFunction;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;
import compiler.types.TypedAst.TypedFunction;
import compiler.types.TypedAst.TypedFunctionRole;
import compiler.types.typing.HelperRequests.HelperRequest;

/**
 * An enum's methods lower to statically dispatched functions: an instance method takes the enum value first, a static one
 * takes only its arguments.
 */
class EnumConformanceMethods {
	public static function method(session:TypingSession, type:CompilerType, name:String):Null<AstFunction> {
		return switch type {
			case TInstance(NominalKind.Enum, owner, _):
				var declaration = session.enumDecls.get(owner), found:Null<AstFunction> = null;
				if (declaration != null && declaration.methods != null)
					for (candidate in declaration.methods) if (candidate.name == name) found = candidate;
				found;
			default: null;
		};
	}

	public static inline final PREFIX = "$enum-custom:";

	/** The helper for `method` of the enum `type`, with the method's own `typeArguments` when it is generic. */
	public static function name(type:CompilerType, method:String, ?typeArguments:Array<CompilerType>):String
		return PREFIX + method + ":"
			+ TextDigest.sha256(compiler.semantic.SemanticSignature.type(type) + typeArgumentsSignature(typeArguments))
			.substr(0, 32);

	/**
	 * What the helper serves for its enum type: the method, and for a generic method its type arguments, since each of
	 * those is a helper of its own and the provider table holds one helper per type and operation.
	 */
	static function operation(method:String, typeArguments:Array<CompilerType>):ProviderOperation
		return ProviderOperations.detailed(ProviderOperation.CustomMethod,
			method + typeArgumentsSignature(typeArguments));

	static function typeArgumentsSignature(typeArguments:Null<Array<CompilerType>>):String
		return typeArguments == null || typeArguments.length == 0 ? "" : "<"
			+ [for (argument in typeArguments) compiler.semantic.SemanticSignature.type(argument)].join(",")
			+ ">";

	/**
	 * Requests `method` of the enum `type`, with the method's own closed `typeArguments`, and returns the type it is keyed
	 * by (see `ValueEqualityGenerator.request`).
	 */
	public static function request(session:TypingSession, type:CompilerType, method:String, origin:String,
			span:SourceSpan, ?typeArguments:Array<CompilerType>):CompilerType {
		type = session.monomorphs.closeReached(type);
		var arguments = typeArguments == null ? [] : typeArguments,
			key = name(type, method, arguments);
		session.requestHelper(EnumMethodHelper(key, {
			type: type,
			method: method,
			typeArguments: arguments,
			origin: origin,
			span: span
		}));
		return type;
	}

	public static function generate(session:TypingSession, typer:BodyTyper):Array<TypedFunction> {
		var generated:Map<String, TypedFunction> = [];
		while (true) {
			var pending =
				[for (key in session.programOutput.requests.enumMethods.keys()) if (!generated.exists(key)) key];
			if (pending.length == 0) break;
			pending.sort(Reflect.compare);
			for (key in pending) {
				var requested = session.programOutput.requests.enumMethods.get(key);
				if (requested == null) throw new InternalError('Missing enum method request "$key"');
				generated.set(key, session.typeHelper(key, () -> {
					var implementation = method(session, requested.type, requested.method);
					if (implementation == null) throw new InternalError('Missing enum method implementation "$key"');
					typeMethod(session, typer, requested.type, implementation, requested.origin,
						requested.typeArguments);
				}));
			}
		}
		var keys = [for (key in generated.keys()) key];
		keys.sort(Reflect.compare);
		return [for (key in keys) generated.get(key)];
	}

	public static function typeMethod(session:TypingSession, typer:BodyTyper, type:CompilerType, method:AstFunction,
			origin:String, ?typeArguments:Array<CompilerType>):TypedFunction {
		return switch type {
			case TInstance(NominalKind.Enum, owner, arguments):
				// Typed from the enum's method as the program has it.
				session.readSignature(owner + "." + method.name);
				session.readBody(owner + "." + method.name);
				var declaration = session.enumDecls.get(owner), substitutions:Map<String, CompilerType> = [];
				if (declaration == null) throw new InternalError('Missing enum declaration "$owner"');
				for (index in 0...declaration.typeParameters.length)
					substitutions.set(declaration.typeParameters[index], index < arguments.length ? arguments[index]
						: TTypeParameter(owner, declaration.typeParameters[index]));
				// A generic method is typed once per type arguments, as the enum is per its own.
				var parameters = BodyTyper.functionTypeParameters(method),
					given = typeArguments == null ? [] : typeArguments;
				if (given.length != parameters.length)
					throw new InternalError('Enum method "$owner.${method.name}" requested without its type arguments');
				for (index in 0...parameters.length)
					substitutions.set(parameters[index], given[index]);
				// A static method has no value to take: it is typed like a class's static.
				var typed = typer.typeFunction(method, owner, true, substitutions, name(type, method.name, given),
					method.isStatic ? null : type);
				{
					name:typed.name, role:ProviderFunction(type, operation(method.name, given)), origin:origin,
						originKind:Helper, typeArguments:null, owner:null,
						isStatic:true, isConstructor:false, isInline:typed.isInline, isKept:false, isExposed:false,
						arguments:typed.arguments, result:typed.result, statements:typed.statements,
						cells:typed.cells, cellCaptures:typed.cellCaptures, span:typed.span
				};
			default: throw new InternalError('Invalid enum conformance method receiver "$type"');
		};
	}
}
