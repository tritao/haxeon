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
			if (!indegree.exists(name))
				throw 'Missing initialization indegree for module "$name"';
			var state = states.get(name);
			for (dependency in state.dependencies)
				if (known.exists(dependency) && outgoing.exists(dependency)) {
					indegree.set(name, indegree.get(name) + 1);
					var dependents = outgoing.get(dependency);
					dependents.push(name);
				}
		}
		var orderedNames = names.copy(),
			ready:Array<String> = [],
			result:Array<String> = [],
			emitted:Map<String, Bool> = [];
		orderedNames.sort(Reflect.compare);
		for (name in orderedNames)
			if (indegree.exists(name) && indegree.get(name) == 0)
				heapPush(ready, name);
		while (ready.length > 0) {
			var name = heapPop(ready);
			emitted.set(name, true);
			result.push(name);
			if (!outgoing.exists(name))
				throw 'Missing initialization dependents for module "$name"';
			for (dependent in outgoing.get(name)) {
				if (!indegree.exists(dependent))
					throw 'Missing initialization indegree for dependent module "$dependent"';
				var next = indegree.get(dependent) - 1;
				indegree.set(dependent, next);
				if (next == 0)
					heapPush(ready, dependent);
			}
		}
		if (result.length != orderedNames.length)
			for (name in orderedNames)
				if (!emitted.exists(name))
					result.push(name);
		return result;
	}

	static function heapPush(heap:Array<String>, value:String):Void {
		var index = heap.length;
		heap.push(value);
		while (index > 0) {
			var parent = (index - 1) >> 1;
			if (Reflect.compare(heap[parent], value) <= 0)
				break;
			heap[index] = heap[parent];
			index = parent;
		}
		heap[index] = value;
	}

	static function heapPop(heap:Array<String>):String {
		var result = heap[0], tail = heap.pop();
		if (heap.length > 0) {
			var index = 0;
			while (true) {
				var left = index * 2 + 1;
				if (left >= heap.length)
					break;
				var right = left + 1,
					child = right < heap.length && Reflect.compare(heap[right], heap[left]) < 0 ? right : left;
				if (Reflect.compare(heap[child], tail) >= 0)
					break;
				heap[index] = heap[child];
				index = child;
			}
			heap[index] = tail;
		}
		return result;
	}
}
