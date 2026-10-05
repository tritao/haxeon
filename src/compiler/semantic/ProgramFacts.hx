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
