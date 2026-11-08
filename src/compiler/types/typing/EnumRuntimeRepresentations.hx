package compiler.types.typing;

import compiler.syntax.Ast.AstEnumParameter;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;
import compiler.types.TypedAst.TypedEnum;

/** Concrete enum declarations are retained before erasure, including cases which do not mention T. */
class EnumRuntimeRepresentations {
	final session:TypingSession;
	final requested:Map<String, CompilerType> = [];
	final queue:Array<CompilerType> = [];
	final recursion:EnumRecursion;
	final descriptorRecursion:EnumRecursion;

	public function new(session:TypingSession) {
		this.session = session;
		recursion = new EnumRecursion(session);
		descriptorRecursion = new EnumRecursion(session, BoxedDescriptor);
	}

	public function count():Int return queue.length;

	public function discover(type:CompilerType, ?seen:Array<Array<compiler.types.Type.AnonymousField>>):Void {
		switch type {
			case TInstance(NominalKind.Enum, _, arguments):
				if (arguments.length > 0 && !session.representation.containsTypeParameter(type, [])) {
					var name = EnumRuntimeType.name(type);
					if (!requested.exists(name)) { requested.set(name, type); queue.push(type); }
				}
				// Arguments contribute to identity, not necessarily storage. The instantiated
				// payloads are discovered when this declaration is drained below.
			case TInstance(_, _, _):
			case TAbstract(_, _, representation): discover(representation, seen);
			case TNullable(element), TArray(element), TIterator(element): discover(element, seen);
			case TMap(key, value), TKeyPath(key, value, _): discover(key, seen); discover(value, seen);
			case TFunction(arguments, result):
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
				discover(TInstance(NominalKind.Enum, declaration.specializationOrigin, declaration.specializationArguments));

	public function declaration(index:Int):TypedEnum {
		var type = queue[index], origin = switch type { case TInstance(_, name, _): name; default: throw "Invalid enum request"; };
		var source = session.enumDecls.get(origin);
		if (source == null) throw 'Missing enum declaration "$origin"';
		var arguments = switch type { case TInstance(_, _, arguments): arguments; default: []; };
		return {
			name: EnumRuntimeType.name(type), specializationOrigin: origin, specializationArguments: arguments,
			isRecursive: isRecursive(origin),
			equatable: DeclaredConformance.has(session, type, "Equatable"),
			hashable: DeclaredConformance.has(session, type, "Hashable"), metadata: source.metadata,
			cases: [for (constructor in source.cases) {
				name: constructor.name, metadata: constructor.metadata, span: constructor.span,
				params: [for (parameter in constructor.params) storage(source.typeParameters, parameter, type)]
			}], span: source.span
		};
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
