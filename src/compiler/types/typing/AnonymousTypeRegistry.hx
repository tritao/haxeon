package compiler.types.typing;

import compiler.types.Type.CompilerType;

/** Records structural types discovered while bodies are typed. */
class AnonymousTypeRegistry {
	final session:TypingSession;

	public function new(session:TypingSession)
		this.session = session;

	/** Attributes every anonymous type `type` reaches to the unit being typed, whether or not it was registered before. */
	function recordUses(type:CompilerType, seen:Map<String, Bool>):Void
		switch type {
			case TAnonymous(name, fields):
				if (seen.exists(name))
					return;
				seen.set(name, true);
				session.recordAnonymousUse(name, fields);
				for (field in fields)
					recordUses(field.type, seen);
			case TNullable(element), TArray(element), TIterator(element):
				recordUses(element, seen);
			case TKeyPath(root, value, _):
				var name = compiler.types.KeyPathType.descriptorName(root, value);
				if (!seen.exists(name)) {
					seen.set(name, true);
					session.recordAnonymousUse(name, compiler.types.KeyPathType.fields(root, value));
				}
				recordUses(root, seen);
				recordUses(value, seen);
			case TMap(key, value):
				recordUses(key, seen);
				recordUses(value, seen);
			case TFunction(arguments, result):
				for (argument in arguments)
					recordUses(argument, seen);
				recordUses(result, seen);
			default:
		}

	public function register(type:CompilerType):Void {
		recordUses(type, []);
		discover(type);
	}

	function discover(type:CompilerType):Void
		switch type {
			case TAnonymous(name, fields):
				if (session.anonymousTypes.exists(name))
					return;
				session.anonymousTypes.set(name, fields);
				for (field in fields)
					discover(field.type);
			case TNullable(element), TArray(element), TIterator(element):
				discover(element);
			case TKeyPath(root, value, _):
				var name = compiler.types.KeyPathType.descriptorName(root, value);
				if (!session.anonymousTypes.exists(name))
					session.anonymousTypes.set(name, compiler.types.KeyPathType.fields(root, value));
				discover(root);
				discover(value);
			case TMap(key, value):
				discover(key);
				discover(value);
			case TFunction(arguments, result):
				for (argument in arguments)
					discover(argument);
				discover(result);
			default:
		}
}
