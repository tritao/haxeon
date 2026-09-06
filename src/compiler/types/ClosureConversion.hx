package compiler.types;

import compiler.types.Type.CompilerType;
import compiler.types.TypedAst.CellStorageKind;
import compiler.types.TypedAst.TypedCapture;
import compiler.types.TypedAst.TypedCaptureEnvironment;
import compiler.types.TypedAst.TypedCell;
import compiler.types.TypedAst.TypedFunction;

/** Collects the runtime artifacts produced by closure conversion. */
class ClosureConversion {
	final functions:Array<TypedFunction> = [];
	final cells:Array<TypedCell> = [];
	final environments:Array<TypedCaptureEnvironment> = [];
	final cellNames:Map<String, Bool> = [];
	final environmentNames:Map<String, Bool> = [];

	public function new() {}

	public function addFunction(fn:TypedFunction):Void
		functions.push(fn);

	public function addCell(name:String, valueType:CompilerType, kind:CellStorageKind):Void {
		if (cellNames.exists(name))
			return;
		cellNames.set(name, true);
		cells.push({name: name, valueType: valueType, kind: kind});
	}

	public function addEnvironment(name:String, captures:Array<TypedCapture>):Void {
		if (environmentNames.exists(name))
			return;
		environmentNames.set(name, true);
		environments.push({
			name: name,
			fields: [
				for (capture in captures)
					{
						name: capture.field,
						type: switch capture.source {
							case CaptureCellLocal(_, cellClass), CaptureCellEnvironmentField(_, cellClass): TClass(cellClass);
							default: capture.type;
						}
					}
			]
		});
	}

	public function generatedFunctions():Array<TypedFunction>
		return functions.copy();

	public function generatedCells():Array<TypedCell>
		return cells.copy();

	public function generatedEnvironments():Array<TypedCaptureEnvironment>
		return environments.copy();
}
