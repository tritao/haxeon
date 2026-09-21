package build.execution;

class ExecutionPlan {
	public final actions:Array<ExecutionAction>;

	final byKey:Map<String, ExecutionAction>;

	public function new(actions:Array<ExecutionAction>) {
		var supplied = actions.copy();
		byKey = new Map();
		for (action in supplied) {
			if (byKey.exists(action.id.key()))
				throw 'Duplicate execution action: ${action.id}';
			byKey.set(action.id.key(), action);
		}
		for (action in supplied)
			for (dependency in action.dependencies)
				if (!byKey.exists(dependency.key()))
					throw 'Action ${action.id} depends on missing action $dependency';
		this.actions = topologicalOrder(supplied);
	}

	public function action(id:ActionId):Null<ExecutionAction>
		return byKey.get(id.key());

	public function toDebugString():String {
		var output = new StringBuf(), index = 1;
		for (action in actions) {
			output.add('[$index] ${action.id}\n');
			output.add('    description: ${action.description}\n');
			output.add('    kind: ${kindName(action)}\n');
			if (action.dependencies.length > 0)
				for (dependency in action.dependencies)
					output.add('    after $dependency\n');
			if (action.inputs.length > 0)
				output.add('    inputs: ${action.inputs.join(", ")}\n');
			if (action.outputs.length > 0)
				output.add('    outputs: ${action.outputs.join(", ")}\n');
			index++;
		}
		return output.toString();
	}

	static function kindName(action:ExecutionAction):String
		return switch action.action {
			case Process(_, _, _, _): "process";
			case Compiler(_, _, _): "compiler";
		};

	function topologicalOrder(supplied:Array<ExecutionAction>):Array<ExecutionAction> {
		var pending = new Map<String, ExecutionAction>(),
			emitted = new Map<String, Bool>(),
			result:Array<ExecutionAction> = [];
		for (action in supplied)
			pending.set(action.id.key(), action);
		while (pending.iterator().hasNext()) {
			var ready = [for (action in pending) if (dependenciesEmitted(action, emitted)) action];
			if (ready.length == 0)
				throw "Execution plan contains a dependency cycle";
			ready.sort((left, right) -> Reflect.compare(left.id.key(), right.id.key()));
			for (action in ready) {
				result.push(action);
				emitted.set(action.id.key(), true);
				pending.remove(action.id.key());
			}
		}
		return result;
	}

	static function dependenciesEmitted(action:ExecutionAction, emitted:Map<String, Bool>):Bool {
		for (dependency in action.dependencies)
			if (!emitted.exists(dependency.key()))
				return false;
		return true;
	}
}
