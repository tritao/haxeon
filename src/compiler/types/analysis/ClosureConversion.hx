package compiler.types.analysis;

import compiler.types.Type.CompilerType;
import compiler.types.TypedAst.CellStorageKind;
import compiler.types.TypedAst.TypedCapture;
import compiler.types.TypedAst.TypedClosurePlan;
import compiler.types.TypedAst.TypedEnvironmentRequirement;
import compiler.types.TypedAst.TypedFunction;
import compiler.types.TypedAst.TypedStorageRequirement;

/** How much closure conversion had collected at some point: what was added after it is counted from here. */
typedef ClosureConversionMark = {
	final functions:Int;
	final storage:Int;
	final environments:Int;
}

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

	public function generatedFunctionCount():Int
		return functions.length;

	public function generatedFunction(index:Int):TypedFunction
		return functions[index];

	public function mark():ClosureConversionMark
		return {functions: functions.length, storage: storage.length, environments: environments.length};

	/** Passes the types of everything added since `from` through `map` (see `TypedTypeMap`). */
	public function mapTypesSince(from:ClosureConversionMark, map:compiler.types.TypedTypeMap):Void {
		for (index in from.functions...functions.length)
			functions[index] = map.typedFunction(functions[index]);
		for (index in from.storage...storage.length) {
			var requirement = storage[index];
			storage[index] = {
				name: requirement.name,
				valueType: map.type(requirement.valueType),
				kind: requirement.kind
			};
		}
		for (index in from.environments...environments.length) {
			var requirement = environments[index];
			environments[index] = {
				name: requirement.name,
				captures: [for (item in requirement.captures) map.capture(item)]
			};
		}
	}

	public function plan():TypedClosurePlan
		return {storage: storage.copy(), environments: environments.copy()};
}
