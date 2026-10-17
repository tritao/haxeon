package compiler.ir;

import compiler.ir.Ir;

/** Calls that can execute while evaluating a function, excluding callbacks only stored for later. */
class IrInitializationCalls {
	final functions:Map<String, IrFunction>;
	final methods:Map<String, Array<String>> = [];
	final invoked:Map<String, Bool> = [];
	final objects:Map<String, IrObject>;
	final resolvedMethods:Map<String, Array<String>> = [];

	public function new(program:Array<IrFunction>, ?objects:Array<IrObject>) {
		this.objects = objects == null ? [] : [for (object in objects) object.name => object];
		functions = [for (fn in program) fn.name => fn];
		for (fn in program) {
			var dot = fn.name.lastIndexOf(".");
			if (dot < 0)
				continue;
			var method = fn.name.substr(dot + 1);
			if (!methods.exists(method))
				methods.set(method, []);
			methods.get(method).push(fn.name);
		}
	}

	public function calls(fn:IrFunction):Array<String> {
		var result:Array<String> = [], closures:Map<Int, Array<String>> = [];
		for (block in fn.blocks)
			for (instruction in block.instructions)
				switch instruction.value {
					case StaticClosure(out, callee), InstanceClosure(out, callee, _):
						closures.set(out.id, [callee]);
					case _:
				}
		propagate(fn, closures);
		function addCallbacks(callee:String, arguments:Array<IrValue>, offset:Int):Void {
			for (index in 0...arguments.length)
				if (closures.exists(arguments[index].id) && invokesArgument(callee, index + offset, []))
					for (target in closures.get(arguments[index].id))
						result.push(target);
		}
		for (block in fn.blocks)
			for (instruction in block.instructions)
				switch instruction.value {
					case Call(_, callee, arguments):
						result.push(callee);
						addCallbacks(callee, arguments, 0);
					case CallClosure(_, closure, _):
						if (closures.exists(closure.id))
							result = result.concat(closures.get(closure.id));
					case MethodCall(_, receiver, method, arguments):
						for (callee in methodTargets(receiver, method)) {
							result.push(callee);
							addCallbacks(callee, arguments, 1);
						}
					case _:
				}
		return result;
	}

	function methodTargets(receiver:IrValue, method:String):Array<String> {
		var owner:Null<String> = switch receiver.type {
			case Obj(name): name;
			case _: null;
		};
		if (owner == null || !objects.exists(owner))
			return methods.exists(method) ? methods.get(method) : [];
		var key = owner + "." + method;
		if (resolvedMethods.exists(key))
			return resolvedMethods.get(key);
		var result:Array<String> = [];
		for (object in objects) {
			var current:Null<IrObject> = object, matches = false;
			while (current != null) {
				if (current.name == owner) {
					matches = true;
					break;
				}
				current = current.base == null ? null : objects.get(current.base);
			}
			if (!matches)
				continue;
			current = object;
			while (current != null) {
				var target:Null<String> = null;
				for (entry in current.methods)
					if (entry.name == method) {
						target = entry.functionName;
						break;
					}
				if (target != null) {
					if (!result.contains(target))
						result.push(target);
					break;
				}
				current = current.base == null ? null : objects.get(current.base);
			}
		}
		result.sort(Reflect.compare);
		resolvedMethods.set(key, result);
		return result;
	}

	function invokesArgument(name:String, index:Int, seen:Map<String, Bool>):Bool {
		var key = name + ":" + index;
		if (invoked.exists(key))
			return invoked.get(key);
		if (!functions.exists(name) || seen.exists(key))
			return false;
		var fn = functions.get(name);
		if (index >= fn.arguments.length)
			return false;
		var root = !seen.keys().hasNext();
		seen.set(key, true);
		var aliases:Map<Int, Array<String>> = [fn.arguments[index].id => ["argument"]];
		propagate(fn, aliases);
		var found = false;
		for (block in fn.blocks)
			for (instruction in block.instructions)
				switch instruction.value {
					case CallClosure(_, closure, _):
						if (aliases.exists(closure.id))
							found = true;
					case Call(_, callee, arguments):
						for (argument in 0...arguments.length)
							if (aliases.exists(arguments[argument].id) && invokesArgument(callee, argument, seen))
								found = true;
					case MethodCall(_, receiver, method, arguments):
						for (callee in methodTargets(receiver, method))
							for (argument in 0...arguments.length)
								if (aliases.exists(arguments[argument].id) && invokesArgument(callee, argument + 1, seen))
									found = true;
					case _:
				}
		// Each argument is explored once per search, even through recursive forwarding graphs.
		// Only root negatives are complete; a nested search may have skipped an active caller.
		if (found || root)
			invoked.set(key, found);
		return found;
	}

	/** Preserve possible closure origins through SSA aliases and joins. */
	static function propagate(fn:IrFunction, origins:Map<Int, Array<String>>):Void {
		var fields:Map<String, Array<String>> = [];
		var changed = true;
		while (changed) {
			changed = false;
			for (block in fn.blocks)
				for (instruction in block.instructions) {
					switch instruction.value {
						case FieldSet(object, field, value) if (origins.exists(value.id)):
							var key = object.id + ":" + field;
							if (!fields.exists(key))
								fields.set(key, []);
							for (origin in origins.get(value.id))
								if (!fields.get(key).contains(origin)) {
									fields.get(key).push(origin);
									changed = true;
								}
						case _:
					}
					var output = IrOperands.output(instruction.value);
					if (output == null)
						continue;
					switch instruction.value {
						case FieldGet(_, object, field) if (fields.exists(object.id + ":" + field)):
							if (!origins.exists(output.id))
								origins.set(output.id, []);
							for (origin in fields.get(object.id + ":" + field))
								if (!origins.get(output.id).contains(origin)) {
									origins.get(output.id).push(origin);
									changed = true;
								}
						case _:
					}
					var inputs = switch instruction.value {
						case SafeCast(_, value), ToDyn(_, value), ToVirtual(_, value): [value];
						case Phi(_, values): [for (input in values) input.value];
						case _: [];
					};
					for (input in inputs)
						if (origins.exists(input.id))
							for (origin in origins.get(input.id)) {
								if (!origins.exists(output.id))
									origins.set(output.id, []);
								if (!origins.get(output.id).contains(origin)) {
									origins.get(output.id).push(origin);
									changed = true;
								}
							}
				}
		}
	}
}
