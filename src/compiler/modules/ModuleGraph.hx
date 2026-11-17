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
}
