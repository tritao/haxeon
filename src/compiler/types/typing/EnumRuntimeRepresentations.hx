package compiler.types.typing;

import compiler.core.InternalError;
import compiler.syntax.Ast.AstEnumParameter;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;
import compiler.types.TypedAst.TypedEnum;

/** Concrete enum declarations are retained before erasure, including cases which do not mention T. */
class EnumRuntimeRepresentations {
	final session:TypingSession;
	final recursion:EnumRecursion;
	final descriptorRecursion:EnumRecursion;

	public function new(session:TypingSession) {
		this.session = session;
		recursion = new EnumRecursion(session);
		descriptorRecursion = new EnumRecursion(session, BoxedDescriptor);
	}

	public function count():Int return session.programOutput.enumCount();

	public function discover(type:CompilerType, ?seen:Array<Array<compiler.types.Type.AnonymousField>>):Void {
		switch type {
			case TInstance(NominalKind.Enum, _, arguments):
				// An argument a type variable or an open literal structure still holds open is known when the body is typed (`Some(null)`,
				// `None`, `Some({a: 1})`).
				if (arguments.length > 0
					&& (compiler.types.Monomorphs.containsUnbound(type) || session.monomorphs.mentionsOpen(type)))
					session.monomorphs.whenKnown(type, () -> discover(session.monomorphs.settled(type)));
				else if (arguments.length > 0) {
					// A new local, not `type` again: a closure above captures `type`, and writing it would keep it in a cell on
					// every call.
					var resolved = compiler.types.Monomorphs.resolve(type);
					if (!session.representation.containsTypeParameter(resolved, []))
						session.output.discoverEnum(EnumRuntimeType.name(resolved), resolved);
				}
			// Arguments contribute to identity, not necessarily storage. The instantiated
			// payloads are discovered when this declaration is drained below.
			case TInstance(_, _, _):
			case TAbstract(_, _, representation): discover(representation, seen);
			case TNullable(element), TArray(element), TIterator(element): discover(element, seen);
			case TMap(key, value), TKeyPath(key, value, _): discover(key, seen);
				discover(value, seen);
			case TFunction(arguments, result, _):
				for (argument in arguments) discover(argument, seen);
				discover(result, seen);
			case TAnonymous(_, fields):
				if (seen == null) seen = [];
				if (seen.indexOf(fields) < 0) {
					seen.push(fields);
					for (field in fields) discover(field.type, seen);
					seen.pop();
				}
			default:
		}
	}

	/** Ask again for the retained specializations of `enums`, so unchanged incremental callers keep their names. */
	public function restore(enums:Array<TypedEnum>, retained:Map<String, Bool>):Void
		for (declaration in enums)
			if (declaration.specializationOrigin != null
				&& retained.exists(declaration.name)
				&& session.enumDecls.exists(declaration.specializationOrigin)
				&& session.representation.typeNamesExist(declaration.specializationArguments))
				discover(TInstance(NominalKind.Enum, declaration.specializationOrigin,
					declaration.specializationArguments));

	public function declaration(index:Int):TypedEnum {
		var type = session.programOutput.enumType(index), origin = switch type {
			case TInstance(_, name, _): name;
			default: throw new InternalError("Invalid enum request");
		};
		var source = session.enumDecls.get(origin);
		if (source == null) throw new InternalError('Missing enum declaration "$origin"');
		var arguments = switch type {
			case TInstance(_, _, arguments): arguments;
			default: [];
		};
		return {name: EnumRuntimeType.name(type), specializationOrigin: origin, specializationArguments: arguments,
			isRecursive: isRecursive(origin),
			equatable: DeclaredConformance.has(session, type, "Equatable"),
			hashable: DeclaredConformance.has(session, type, "Hashable"), metadata: source.metadata,
			cases: [for (constructor in source.cases) {
				name:constructor.name, metadata:constructor.metadata, span:constructor.span,
					params:[for (parameter in constructor.params) storage(source.typeParameters, parameter, type)]
			}], span: source.span};
	}

	public function storage(parameters:Array<String>, parameter:AstEnumParameter, instance:CompilerType):CompilerType {
		var name = EnumRuntimeType.name(instance), origin = name == null ? null : EnumRuntimeType.declaration(name);
		// The existing boxed generic transport needs a finite descriptor graph even for
		// E<T> -> Array<E<Array<T>>>. This does not make a reference cycle recursive by
		// value or reject its inline layout; source value transport remains a later step.
		if (parameters.length > 0 && origin != null && descriptorRecursion.isRecursive(origin)) return TDynamic;
		return session.representation.enumParameterType(parameters, parameter, instance);
	}

	public function isRecursive(name:String):Bool return recursion.isRecursive(name);
}
