package compiler.types.typing;

import compiler.types.Type.CompilerType;

/** Records structural types discovered while bodies are typed. */
class AnonymousTypeRegistry {
	final session:TypingSession;

	public function new(session:TypingSession)
		this.session = session;

	/**
	 * Attributes the anonymous types a function's signature reaches to the function's unit. A build that does not type the
	 * function again keeps them with its body's (`ProgramTyper.keepStructures`), so the program lists the same types whichever
	 * functions a build typed, as a fresh build, which registers every signature, does.
	 */
	public function recordSignature(unit:String, type:CompilerType):Void {
		var uses = ProgramTypeUses.structuresOf(session, type);
		if (uses != null)
			attribute(uses, unit);
	}

	/**
	 * Registers the structures `type` reaches with the program, and attributes them to the unit being typed. A unit typed to be
	 * checked and dropped adds no type to the program, and a shared unit's types wait for its merge.
	 */
	public function register(type:CompilerType):Void {
		var representation = session.currentContext.localTypeRepresentation;
		if (representation != null)
			type = representation(type);
		var uses = ProgramTypeUses.structuresOf(session, type);
		if (uses == null)
			return;
		attribute(uses, null);
		var output = session.output;
		if (output.checkOnly)
			return;
		if (output.shared)
			output.deferStructures(uses);
		else
			uses.registerStructures(session);
	}

	/** Attributes the structures of `uses` to `unit`, or when it is null to the unit being typed. */
	function attribute(uses:ProgramTypeUses, unit:Null<String>):Void {
		var structures = uses.structures;
		if (structures != null)
			for (structure in structures)
				if (unit == null)
					session.recordAnonymousUse(structure.name, structure.fields);
				else
					session.programOutput.records.recordAnonymousUse(unit, structure.name, structure.fields);
	}
}
