package compiler.types.typing;

import compiler.compilation.AllocationMeter.PhaseAllocation;
import compiler.types.TypedAst.TypedProgram;

typedef TyperPhaseMetrics = {
	final allocationPhases:Array<PhaseAllocation>;
	final declarationMs:Float;
	final shapeConnectionMs:Float;
	final signatureTypingMs:Float;
	final setupMs:Float;
	final noReturnMs:Float;

	/** Enum, interface and class declarations (fields, signatures, native layouts); no bodies. */
	final metadataMs:Float;

	/** Source class method and initializer bodies. */
	final classBodiesMs:Float;

	/** Source top-level functions and static abstract methods. */
	final functionBodiesMs:Float;

	/** Generic owner specializations and generated helpers (equality, flags, codecs, adapters), drained to a fixed point. */
	final generatedMs:Float;

	final bodyTransitionMs:Float;
	final assemblyMs:Float;
	final finalizationMs:Float;
}

typedef MeasuredTypedProgram = {
	final program:TypedProgram;
	final metrics:TyperPhaseMetrics;
	final runtimeDependencies:Array<{var functionName:String; var target:String;}>;

	/** Purity/no-return answers each freshly typed function's body depended on, keyed by that
	 * function's own name. See `TypingSession.purityQueries`/`noReturnQueries`.
	 */
	final purityQueries:Map<String, Map<String, Bool>>;

	final noReturnQueries:Map<String, Map<String, Bool>>;

	/** The key path literals each freshly typed function uses, by function name. */
	final keyPathUses:Map<String, Map<String, Bool>>;

	final inlineConstantDependencies:Map<String, Map<String, Bool>>;
	final defaultArgumentSources:Map<String, Map<String, compiler.Source.SourceFile>>;
}
