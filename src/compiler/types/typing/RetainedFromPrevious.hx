package compiler.types.typing;

import compiler.types.TypedAst.TypedProgram;

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
}
