package compiler.types.typing;

import compiler.types.Type.CompilerType;

/** Records structural types discovered while bodies are typed. */
class AnonymousTypeRegistry {
	final session:TypingSession;

	public function new(session:TypingSession)
		this.session = session;

	public function register(type:CompilerType):Void
		switch type {
			case TAnonymous(name, fields):
				if (session.anonymousTypes.exists(name))
					return;
				session.anonymousTypes.set(name, fields);
				for (field in fields)
					register(field.type);
			case TNullable(element), TArray(element), TIterator(element):
				register(element);
			case TMap(key, value):
				register(key);
				register(value);
			case TFunction(arguments, result):
				for (argument in arguments)
					register(argument);
				register(result);
			default:
		}
}
