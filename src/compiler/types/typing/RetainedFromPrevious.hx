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
	 * The anonymous types the units this build keeps registered when they were typed, given the units it typed: the program lists
	 * them, as a fresh build, which types every unit, does (`compiler.compilation.ModuleStructures`).
	 */
	final structures:(typed:Map<String, Bool>) -> Array<Array<compiler.types.TypedAst.TypedAnonymous>>;

	/**
	 * The generated helpers the build keeps without typing them again, by name: not selected or invalidated, nor made for an origin
	 * that is. One the build asks for again from the same origin is the last build's (`TypingSession.keptHelper`), as a unit that read
	 * nothing that changed.
	 */
	final helpers:Map<String, compiler.types.TypedAst.TypedFunction>;

	/**
	 * The generic owner specializations of the previous program that nothing they read changed since, by name: one the build asks
	 * for again is the last build's (`SessionState.ownerSpecializations`).
	 */
	final specializations:Map<String, OwnerSpecialization>;
}
