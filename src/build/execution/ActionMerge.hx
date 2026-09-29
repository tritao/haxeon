package build.execution;

import build.execution.ExecutionAction.ActionKind;

/**
 * Merges actions that share an identity. Shared CMake nodes are requested by several packages, and each
 * lists only the inputs it knows about, so a match keeps the command and unions the inputs. A node whose
 * command or outputs differ is a conflict, never a silent overwrite.
 */
class ActionMerge {
	/** Collapses duplicate ids within one lowering, keeping first-seen order. */
	public static function dedupe(actions:Array<ExecutionAction>):Array<ExecutionAction> {
		var byKey = new Map<String, ExecutionAction>(), order:Array<String> = [];
		for (action in actions) {
			var key = action.id.key(), existing = byKey.get(key);
			if (existing == null) {
				byKey.set(key, action);
				order.push(key);
			} else
				byKey.set(key, combine(existing, action, "the same project", "another package"));
		}
		return [for (key in order) byKey.get(key)];
	}

	public static function combine(existing:ExecutionAction, incoming:ExecutionAction, earlier:String, later:String):ExecutionAction {
		var problems:Array<String> = [];
		if (existing.description != incoming.description)
			problems.push('description "${existing.description}" vs "${incoming.description}"');
		if (existing.outputs.join("\n") != incoming.outputs.join("\n"))
			problems.push('outputs [${existing.outputs.join(", ")}] vs [${incoming.outputs.join(", ")}]');
		if (commandLine(existing) != commandLine(incoming))
			problems.push('command "${commandLine(existing)}" vs "${commandLine(incoming)}"');
		if (existing.alwaysRun != incoming.alwaysRun || existing.fingerprintDependencies != incoming.fingerprintDependencies)
			problems.push("scheduling flags differ");
		if (problems.length > 0)
			throw 'Action ${existing.id} differs between $earlier and $later: ${problems.join("; ")}';
		return new ExecutionAction(existing.id, union(existing.dependencies, incoming.dependencies, id -> id.key()),
			union(existing.inputs, incoming.inputs, path -> path), existing.outputs, existing.description, existing.action, existing.fingerprintDependencies,
			existing.alwaysRun);
	}

	static function union<T>(left:Array<T>, right:Array<T>, key:T->String):Array<T> {
		var seen = new Map<String, Bool>(), result:Array<T> = [];
		for (item in left.concat(right))
			if (!seen.exists(key(item))) {
				seen.set(key(item), true);
				result.push(item);
			}
		return result;
	}

	static function commandLine(action:ExecutionAction):String
		return switch action.action {
			case Process(command, arguments, cwd, _): 'process $command ${arguments.join(" ")} in $cwd';
			case Compiler(command, arguments, cwd, _, _): 'compiler $command ${arguments.join(" ")} in $cwd';
		};
}
