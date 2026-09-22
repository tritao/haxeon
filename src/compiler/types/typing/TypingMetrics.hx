package compiler.types.typing;

import compiler.types.TypedAst.TypedProgram;
import compiler.compilation.AllocationMeter.PhaseAllocation;

typedef TyperPhaseMetrics = {
	final allocationPhases:Array<PhaseAllocation>;
	final declarationMs:Float;
	final shapeConnectionMs:Float;
	final signatureTypingMs:Float;
	final setupMs:Float;
	final noReturnMs:Float;
	final metadataMs:Float;
	final bodiesMs:Float;
	final bodyTransitionMs:Float;
	final assemblyMs:Float;
	final finalizationMs:Float;
}

typedef MeasuredTypedProgram = {
	final program:TypedProgram;
	final metrics:TyperPhaseMetrics;
	final runtimeDependencies:Array<{final functionName:String; final target:String;}>;
}
