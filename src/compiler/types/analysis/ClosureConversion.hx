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

	/** The functions added with `addFunctionOnce`, by name. */
	final onceNames:Map<String, Bool> = [];

	public function new() {}

	public function addFunction(fn:TypedFunction):Void
		functions.push(fn);

	/** Adds `fn` unless a function of its name was added this way before: a helper every user would make the same way. */
	public function addFunctionOnce(fn:TypedFunction):Void {
		if (onceNames.exists(fn.name))
			return;
		onceNames.set(fn.name, true);
		functions.push(fn);
	}

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

	/** Adds to `target` what was added here between `from` and `to`, keeping `target`'s first cell, environment and helper of a name. */
	public function appendTo(target:ClosureConversion, from:ClosureConversionMark, to:ClosureConversionMark):Void {
		for (index in from.functions...to.functions) {
			var fn = functions[index];
			if (onceNames.exists(fn.name))
				target.addFunctionOnce(fn);
			else
				target.addFunction(fn);
		}
		for (index in from.storage...to.storage) {
			var requirement = storage[index];
			target.addCell(requirement.name, requirement.valueType, requirement.kind);
		}
		for (index in from.environments...to.environments) {
			var requirement = environments[index];
			target.addEnvironment(requirement.name, requirement.captures);
		}
	}

	public function plan():TypedClosurePlan
		return {storage: storage.copy(), environments: environments.copy()};
}
