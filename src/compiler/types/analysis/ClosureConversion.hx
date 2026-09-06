package compiler.types.analysis;

import compiler.types.Type.CompilerType;
import compiler.types.TypedAst.CellStorageKind;
import compiler.types.TypedAst.TypedCapture;
import compiler.types.TypedAst.TypedClosurePlan;
import compiler.types.TypedAst.TypedEnvironmentRequirement;
import compiler.types.TypedAst.TypedStorageRequirement;
import compiler.types.TypedAst.TypedFunction;

/** Collects the runtime artifacts produced by closure conversion. */
class ClosureConversion {
	final functions:Array<TypedFunction> = [];
	final storage:Array<TypedStorageRequirement> = [];
	final environments:Array<TypedEnvironmentRequirement> = [];
	final cellNames:Map<String, Bool> = [];
	final environmentNames:Map<String, Bool> = [];

	public function new() {}

	public function addFunction(fn:TypedFunction):Void
		functions.push(fn);

	public function addCell(name:String, valueType:CompilerType, kind:CellStorageKind):Void {
		if (cellNames.exists(name))
			return;
		cellNames.set(name, true);
		storage.push({name: name, valueType: valueType, kind: kind});
	}

	public function addEnvironment(name:String, captures:Array<TypedCapture>):Void {
		if (environmentNames.exists(name))
			return;
		environmentNames.set(name, true);
		environments.push({name: name, captures: captures.copy()});
	}

	public function generatedFunctions():Array<TypedFunction>
		return functions.copy();

	public function plan():TypedClosurePlan
		return {storage: storage.copy(), environments: environments.copy()};
}
