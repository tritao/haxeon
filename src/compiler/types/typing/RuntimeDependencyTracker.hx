package compiler.types.typing;

/** Accumulates runtime helper dependencies requested by typed functions. */
class RuntimeDependencyTracker {
	public static inline final TYPE_ORIGIN_PREFIX = "$type-dependency:";
	final dependencies:Map<String, RuntimeTargets> = [];

	public function new() {}

	/**
		Whether having `target` in the program changes how types are represented, so a body typed without it is typed
		differently than with it. Modules that functions only call (`haxeon.DynamicOps`, `Reflect`, the reactive runtime) do not.
	**/
	public static function changesRepresentation(target:String):Bool
		return target == compiler.runtime.RuntimeType.SPECIALIZED_MAP;

	public function record(functionName:String, target:String):Void {
		var targets = dependencies.get(functionName);
		if (targets == null) {
			// The session's table: made outside the arena of the body being typed, as are the names it keeps.
			targets = compiler.core.Arena.within(compiler.core.Arena.global, () -> new RuntimeTargets());
			dependencies.set(compiler.core.GlobalNames.of(functionName), targets);
		}
		targets.names.set(compiler.core.GlobalNames.of(target), true);
	}

	public function ordered():Array<{
		var functionName:String;
		var target:String;
	}> {
		var result:Array<{
			var functionName:String;
			var target:String;
		}> = [for (functionName => targets in dependencies)
			for (target in targets.names.keys())
			{
			functionName:functionName, target:target
		}];
		result.sort(function(left, right) {
			var functionOrder = Reflect.compare(left.functionName, right.functionName);
			return functionOrder == 0 ? Reflect.compare(left.target, right.target) : functionOrder;
		});
		return result;
	}
}

/**
 * The runtime helpers one function asked for. A class rather than a nested map, so the tracker's table holds typed values whose
 * layout the runtime knows (docs/design/ARENAS.md, "Data rules for arenas").
 */
class RuntimeTargets {
	public final names:Map<String, Bool> = [];

	public function new() {}
}
