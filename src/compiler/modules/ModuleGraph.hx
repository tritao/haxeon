package compiler.modules;

/** Directed module-dependency graph used for deterministic invalidation. */
class ModuleGraph {
	final reverse:Map<String, Array<String>> = [];

	public function new() {}

	public function rebuild(states:Map<String, ModuleState>):Void {
		reverse.clear();
		for (name => state in states)
			for (dependency in state.dependencies) {
				var users:Array<String>;
				if (reverse.exists(dependency))
					users = reverse.get(dependency);
				else {
					users = [];
					reverse.set(dependency, users);
				}
				users.push(name);
			}
	}

	public function dependents(name:String):Array<String> {
		var found:Map<String, Bool> = [], work:Array<String> = [name], result:Array<String> = [], cursor = 0;
		while (cursor < work.length) {
			var current = work[cursor++];
			if (!reverse.exists(current))
				continue;
			var users = reverse.get(current);
			for (user in users)
				if (!found.exists(user)) {
					found.set(user, true);
					result.push(user);
					work.push(user);
				}
		}
		return result;
	}

	/**
		Return modules in dependency-first order for boot-time initialization.
		Independent modules remain lexicographically ordered. Cycles are retained
		in deterministic order; the typer/runtime can then report or handle the
		cycle without making assembly order depend on map iteration.
	 */
	public function initializationOrder(states:Map<String, ModuleState>, names:Array<String>):Array<String> {
		var known:Map<String, Bool> = [];
		for (name in names)
			known.set(name, true);
		var indegree:Map<String, Int> = [],
			outgoing:Map<String, Array<String>> = [];
		for (name in names) {
			indegree.set(name, 0);
			outgoing.set(name, []);
		}
		for (name in names) {
			if (!states.exists(name))
				continue;
			var state = states.get(name);
			for (dependency in state.dependencies)
				if (known.exists(dependency)) {
					indegree.set(name, indegree.get(name) + 1);
					var dependents = outgoing.get(dependency);
					dependents.push(name);
				}
		}
		var orderedNames = names.copy(),
			result:Array<String> = [],
			emitted:Map<String, Bool> = [];
		orderedNames.sort(Reflect.compare);
		while (result.length < orderedNames.length) {
			var candidateIndex = -1;
			for (index in 0...orderedNames.length) {
				var candidate = orderedNames[index];
				if (!emitted.exists(candidate) && indegree.get(candidate) == 0) {
					candidateIndex = index;
					break;
				}
			}
			if (candidateIndex < 0)
				break;
			var name = orderedNames[candidateIndex];
			emitted.set(name, true);
			result.push(name);
			for (dependent in outgoing.get(name)) {
				var next = indegree.get(dependent) - 1;
				indegree.set(dependent, next);
			}
		}
		if (result.length != orderedNames.length)
			for (name in orderedNames)
				if (!emitted.exists(name))
					result.push(name);
		return result;
	}
}
