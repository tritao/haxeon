package compiler.types.typing;

import compiler.types.TypedAst.TypedClass;
import compiler.types.TypedAst.TypedProgram;

/**
 * A generic owner's specialization as the unit a build typed it as (`TypingSession.typeOwnerSpecialization`): the class, and what
 * typing it produced besides (`TypingOutput`: the helpers, owners and enums it asked for, its lambdas, the structures it met). A
 * build that keeps it merges that output again instead of typing the class (`TypingSession.keepOwnerSpecialization`); one without
 * an output is typed again.
 */
typedef OwnerSpecialization = {
	final typed:TypedClass;
	final output:Null<TypingOutput>;
}

/**
	What unchanged code still takes from the previous typed program: the generated classes it refers to (generic owners and
	other classes no source declares), and the enum specializations it uses. The typer asks for these again when it types the
	program, so they are built from the current declarations and nothing else of the previous program is kept.
**/
typedef RetainedFromPrevious = {
	final program:TypedProgram;
	final classes:Map<String, Bool>;

	/** The enum specializations retained code uses. */
	final enums:Map<String, Bool>;

	/**
	 * The functions of the previous program this build keeps without typing them again, generated ones (specializations,
	 * lambdas, adapters) included: whose origin is not invalidated. Their units keep the anonymous types they registered
	 * (`ProgramTyper.keepAnonymousUnits`).
	 */
	final units:Map<String, Bool>;

	/**
	 * The generated helpers among `units`, by name: one the build asks for again from the same origin is the last build's
	 * (`TypingSession.keptHelper`), as a unit that read nothing that changed.
	 */
	final helpers:Map<String, compiler.types.TypedAst.TypedFunction>;

	/**
	 * The generic owner specializations of the previous program that nothing they read changed since, by name: one the build asks
	 * for again is the last build's (`SessionState.ownerSpecializations`).
	 */
	final specializations:Map<String, OwnerSpecialization>;
}
