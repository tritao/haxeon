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
}
