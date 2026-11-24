package compiler.types.typing;

import compiler.core.AllocationMeter.PhaseAllocation;
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
	final runtimeDependencies:Array<{
		var functionName:String;
		var target:String;
	}>;

	/** The key path literals each freshly typed function uses, by function name. */
	final keyPathUses:Map<String, Map<String, Bool>>;

	/** The units this typing typed: function bodies, and field initializers (`Class.__init.x`). */
	final typedUnits:Map<String, Bool>;

	/** The signatures of the unannotated functions whose bodies this typing typed, by key (`DeclarationTypeTable.typedSignatures`). */
	final inferredSignatures:Map<String, compiler.types.DeclarationTypes.InferredSignature>;
}
