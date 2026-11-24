package compiler.semantic;

/**
 * What whole-program inference says about the functions of a canonical program: which are pure, and which never return.
 *
 * `SemanticAssembly` infers them once per compile, because its invalidation compares them with the answers cached bodies were
 * typed against. The typer types the same program, over the same declarations, so it reads these instead of inferring again:
 * what it types against and what the next compile is compared with can only be the same answers.
 */
typedef ProgramFacts = {
	final pure:Map<String, Bool>;
	final noReturn:Map<String, Bool>;
}

/**
 * The facts `SemanticAssembly` inferred for one canonical program, with what it was made of: each module's contribution
 * (`ModuleState.canonicalAllFunctions`, which a module's contribution replaces whenever it is made again), in program order. A
 * program made of the same contributions has the same facts.
 */
typedef InferredProgramFacts = {
	final contributions:Array<Array<compiler.syntax.Ast.AstFunction>>;
	final facts:ProgramFacts;

	/** Whether a function is pure by annotation (or as an intrinsic), over the same program. */
	final isAnnotatedPure:String->Bool;

	/** What each body was found to depend on, for the next inference (`PurityInference.infer`). */
	final dependencies:compiler.types.analysis.PurityInference.PurityDependencies;
}
