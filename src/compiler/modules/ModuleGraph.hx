package compiler.modules;

class ModuleGraph {
	final reverse:Map<String, Array<String>> = [];

	public function new() {}

	public function rebuild(states:Map<String, ModuleState>):Void {
		reverse.clear();
		for (name => state in states)
			for (dependency in state.dependencies) {
				var users = reverse.get(dependency);
				if (users == null) {
					users = [];
					reverse.set(dependency, users);
				}
				users.push(name);
			}
	}

	public function dependents(name:String):Array<String> {
		var found:Map<String, Bool> = [], work = [name], result = [];
		while (work.length > 0) {
			var current = work.pop();
			var users = reverse.get(current);
			if (users == null)
				continue;
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
			var state = states.get(name);
			if (state == null)
				continue;
			for (dependency in state.dependencies)
				if (known.exists(dependency)) {
					indegree.set(name, indegree.get(name) + 1);
					outgoing.get(dependency).push(name);
				}
		}
		var ready = [for (name in names) if (indegree.get(name) == 0) name], result = [];
		while (ready.length > 0) {
			ready.sort(Reflect.compare);
			var name = ready.shift();
			result.push(name);
			for (dependent in outgoing.get(name)) {
				var next = indegree.get(dependent) - 1;
				indegree.set(dependent, next);
				if (next == 0)
					ready.push(dependent);
			}
		}
		if (result.length != names.length)
			for (name in names)
				if (result.indexOf(name) < 0)
					result.push(name);
		return result;
	}
}
