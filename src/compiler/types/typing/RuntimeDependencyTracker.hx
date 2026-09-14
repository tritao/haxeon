package compiler.types.typing;

/** Accumulates runtime helper dependencies requested by typed functions. */
class RuntimeDependencyTracker {
	final dependencies:Map<String, Map<String, Bool>> = [];

	public function new() {}

	public function record(functionName:String, target:String):Void {
		var targets = dependencies.get(functionName);
		if (targets == null) {
			targets = [];
			dependencies.set(functionName, targets);
		}
		targets.set(target, true);
	}

	public function ordered():Array<{final functionName:String; final target:String;}> {
		var result = [
			for (functionName => targets in dependencies)
				for (target in targets.keys())
					{functionName: functionName, target: target}
		];
		result.sort(function(left, right) {
			var functionOrder = Reflect.compare(left.functionName, right.functionName);
			return functionOrder == 0 ? Reflect.compare(left.target, right.target) : functionOrder;
		});
		return result;
	}
}
