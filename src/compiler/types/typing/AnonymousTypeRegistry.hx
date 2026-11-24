package compiler.types.typing;

import compiler.types.Type.CompilerType;

/** Records structural types discovered while bodies are typed. */
class AnonymousTypeRegistry {
	final session:TypingSession;

	public function new(session:TypingSession)
		this.session = session;

	/**
	 * Attributes every anonymous type `type` reaches to a unit, whether or not it was registered before: to `unit`, or when it is
	 * null to the unit being typed.
	 */
	function recordUses(type:CompilerType, seen:Map<String, Bool>, ?unit:String):Void
		switch type {
			// An open literal structure is registered when it is closed, under its final name (`MonomorphFrames`).
			case TAnonymous(name, _) if (compiler.types.Monomorphs.isOpenStructureName(name)):
			// A structure that mentions a type variable is named after its fields once they are known (`Monomorphs.resolve`).
			case TAnonymous(_, _) if (compiler.types.Monomorphs.containsUnbound(type)):
				session.monomorphs.whenKnown(type, () -> discover(session.monomorphs.settled(type)));
			case TAnonymous(name, fields):
				if (seen.exists(name))
					return;
				seen.set(name, true);
				recordUse(name, fields, unit);
				for (field in fields)
					recordUses(field.type, seen, unit);
			case TNullable(element), TArray(element), TIterator(element):
				recordUses(element, seen, unit);
			case TKeyPath(root, value, _):
				var name = compiler.types.KeyPathType.descriptorName(root, value);
				if (!seen.exists(name)) {
					seen.set(name, true);
					recordUse(name, compiler.types.KeyPathType.fields(root, value), unit);
				}
				recordUses(root, seen, unit);
				recordUses(value, seen, unit);
			case TMap(key, value):
				recordUses(key, seen, unit);
				recordUses(value, seen, unit);
			case TFunction(arguments, result, _):
				for (argument in arguments)
					recordUses(argument, seen, unit);
				recordUses(result, seen, unit);
			default:
		}

	function recordUse(name:String, fields:Array<compiler.types.Type.AnonymousField>, unit:Null<String>):Void
		if (unit == null)
			session.recordAnonymousUse(name, fields);
		else
			session.programOutput.records.recordAnonymousUse(unit, name, fields);

	/**
	 * Attributes the anonymous types a function's signature reaches to the function's unit. A build that does not type the
	 * function again keeps them with its body's (`ProgramTyper.keepAnonymousUnits`), so the program lists the same types whichever
	 * functions a build typed, as a fresh build, which registers every signature, does.
	 */
	public function recordSignature(unit:String, type:CompilerType):Void {
		if (compiler.types.Monomorphs.contains(type) && !compiler.types.Monomorphs.containsUnbound(type))
			type = compiler.types.Monomorphs.resolve(type);
		recordUses(type, [], unit);
	}

	public function register(type:CompilerType):Void {
		var representation = session.currentContext.localTypeRepresentation;
		if (representation != null)
			type = representation(type);
		// A type variable already filled is replaced by its type, so a structure is registered under its final name.
		if (compiler.types.Monomorphs.contains(type) && !compiler.types.Monomorphs.containsUnbound(type))
			type = compiler.types.Monomorphs.resolve(type);
		recordUses(type, []);
		// A unit typed to be checked and dropped adds no type to the program, and a shared unit's types wait for its merge.
		var output = session.output;
		if (output.checkOnly)
			return;
		if (output.shared)
			output.deferAnonymousType(type);
		else
			discover(type);
	}

	public function discover(type:CompilerType):Void
		switch type {
			case TAnonymous(name, _) if (compiler.types.Monomorphs.isOpenStructureName(name)):
			// A structure that mentions a type variable is named after its fields once they are known (`Monomorphs.resolve`).
			case TAnonymous(_, _) if (compiler.types.Monomorphs.containsUnbound(type)):
				session.monomorphs.whenKnown(type, () -> discover(session.monomorphs.settled(type)));
			case TAnonymous(name, fields):
				if (session.anonymousTypes.exists(name))
					return;
				// The program's registry: what it keeps is made outside the arena of the unit that met the type first.
				session.anonymousTypes.set(name, compiler.core.Arena.toGlobal(fields));
				for (field in fields)
					discover(field.type);
			case TNullable(element), TArray(element), TIterator(element):
				discover(element);
			case TKeyPath(root, value, _):
				var name = compiler.types.KeyPathType.descriptorName(root, value);
				if (!session.anonymousTypes.exists(name))
					session.anonymousTypes.set(compiler.core.GlobalNames.of(name),
						compiler.core.Arena.toGlobal(compiler.types.KeyPathType.fields(root, value)));
				discover(root);
				discover(value);
			case TMap(key, value):
				discover(key);
				discover(value);
			case TFunction(arguments, result, _):
				for (argument in arguments)
					discover(argument);
				discover(result);
			default:
		}
}
