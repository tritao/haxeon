package compiler.ir;

import compiler.ir.Ir;

/** Calls that can execute while evaluating a function, excluding callbacks only stored for later. */
/**
 * Calls that can execute while evaluating a function, excluding callbacks only stored for later. Reads the functions' bodies
 * (docs/design/IR_CORE_COLUMNS.md).
 */
class IrInitializationCalls {
	final bodies:Map<String, IrBody>;
	final methods:Map<String, Array<String>> = [];
	final invoked:Map<String, Bool> = [];
	final objects:Map<String, IrObject>;

	/** The same objects as a list, for the walk over all of them. */
	final objectList:Array<IrObject>;

	final resolvedMethods:Map<String, Array<String>> = [];
	final globals:Map<String, Array<String>> = [];
	final returns:Map<String, Array<String>> = [];

	/** `program` read as its bodies made with `types`, encoding a function that has none (frozen when `retained`). */
	public function new(program:Array<IrFunction>, types:IrTypeIds, ?objects:Array<IrObject>, ?builder:IrBodyBuilder,
			retained = true) {
		this.objects = objects == null ? [] : [for (object in objects) object.name => object];
		objectList = objects == null ? [] : objects;
		bodies = [for (fn in program) fn.name => fn.bodyIn(types, builder, retained)];
		for (fn in program) {
			var dot = fn.name.lastIndexOf(".");
			if (dot < 0)
				continue;
			var method = fn.name.substr(dot + 1);
			if (!methods.exists(method))
				methods.set(method, []);
			methods.get(method).push(fn.name);
		}
		var summaries:Array<IrBody> = [];
		for (fn in program) {
			var body = bodies.get(fn.name);
			var relevant = switch fn.result {
				case Function(_, _), Dyn: true;
				case _: false;
			};
			if (!relevant)
				for (block in 0...body.blockCount()) {
					var row = body.firstRow(block);
					while (row >= 0 && !relevant) {
						relevant = body.opcode(row) == IrOpcode.GlobalSet;
						row = body.nextRow(row);
					}
				}
			if (relevant)
				summaries.push(body);
		}
		var changed = true;
		while (changed) {
			changed = false;
			for (body in summaries) {
				var origins = closureOrigins(body);
				for (block in 0...body.blockCount()) {
					var row = body.firstRow(block);
					while (row >= 0) {
						switch body.opcode(row) {
							case IrOpcode.GlobalSet if (origins.exists(body.operand(row, 0))):
								if (merge(globals, body.symbol(row).name, origins.get(body.operand(row, 0))))
									changed = true;
							case IrOpcode.Return if (origins.exists(body.operand(row, 0))):
								if (merge(returns, body.name, origins.get(body.operand(row, 0))))
									changed = true;
							case _:
						}
						row = body.nextRow(row);
					}
				}
			}
		}
	}

	static function merge(target:Map<String, Array<String>>, key:String, values:Array<String>):Bool {
		if (!target.exists(key))
			target.set(key, []);
		var changed = false;
		for (value in values)
			if (!target.get(key).contains(value)) {
				target.get(key).push(value);
				changed = true;
			}
		return changed;
	}

	function closureOrigins(body:IrBody):Map<Int, Array<String>> {
		var origins:Map<Int, Array<String>> = [];
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				var out:Int = body.output(row);
				switch body.opcode(row) {
					case IrOpcode.StaticClosure, IrOpcode.InstanceClosure:
						origins.set(out, [body.symbol(row).name]);
					case IrOpcode.GlobalGet if (globals.exists(body.symbol(row).name)):
						origins.set(out, globals.get(body.symbol(row).name).copy());
					case IrOpcode.Call if (returns.exists(body.symbol(row).name)):
						origins.set(out, returns.get(body.symbol(row).name).copy());
					case IrOpcode.MethodCall:
						var found:Array<String> = [];
						for (callee in methodTargets(body.valueType(body.operand(row, 0)), body.symbol(row).name))
							if (returns.exists(callee))
								found = found.concat(returns.get(callee));
						if (found.length > 0)
							origins.set(out, found);
					case _:
				}
				row = body.nextRow(row);
			}
		}
		propagate(body, origins);
		return origins;
	}

	/** What evaluating the function named `name`, one of the program's, can call. */
	public function calls(name:String):Array<String> {
		var body = bodies.get(name);
		var result:Array<String> = [], closures = closureOrigins(body);
		// The callbacks among the operands from `first` on, the callee's arguments from `offset` on.
		function addCallbacks(callee:String, row:Int, first:Int, offset:Int):Void {
			for (index in first...body.operandCount(row)) {
				var argument:Int = body.operand(row, index);
				if (closures.exists(argument) && invokesArgument(callee, index - first + offset, []))
					for (target in closures.get(argument))
						result.push(target);
			}
		}
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				switch body.opcode(row) {
					case IrOpcode.Call:
						var callee = body.symbol(row).name;
						result.push(callee);
						addCallbacks(callee, row, 0, 0);
					case IrOpcode.CallClosure:
						var closure:Int = body.operand(row, 0);
						if (closures.exists(closure))
							result = result.concat(closures.get(closure));
					case IrOpcode.MethodCall:
						for (callee in methodTargets(body.valueType(body.operand(row, 0)), body.symbol(row).name)) {
							result.push(callee);
							addCallbacks(callee, row, 1, 1);
						}
					case _:
				}
				row = body.nextRow(row);
			}
		}
		return result;
	}

	function methodTargets(receiver:IrType, method:String):Array<String> {
		var owner:Null<String> = switch receiver {
			case Obj(name): name;
			case _: null;
		};
		if (owner == null || !objects.exists(owner))
			return methods.exists(method) ? methods.get(method) : [];
		var key = owner + "." + method;
		if (resolvedMethods.exists(key))
			return resolvedMethods.get(key);
		var result:Array<String> = [];
		for (object in objectList) {
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
						target = entry.functionName.name;
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
		if (!bodies.exists(name) || seen.exists(key))
			return false;
		var body = bodies.get(name);
		if (index >= body.argumentCount())
			return false;
		var root = !seen.keys().hasNext();
		seen.set(key, true);
		var aliases:Map<Int, Array<String>> = [(body.argument(index):Int) => ["argument"]];
		propagate(body, aliases);
		var found = false;
		// Whether an operand from `first` on is the argument, passed where the callee invokes it (its arguments from `offset` on).
		function forwards(callee:String, row:Int, first:Int, offset:Int):Void
			for (argument in first...body.operandCount(row))
				if (aliases.exists(body.operand(row, argument))
					&& invokesArgument(callee, argument - first + offset, seen))
					found = true;
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				switch body.opcode(row) {
					case IrOpcode.CallClosure:
						if (aliases.exists(body.operand(row, 0)))
							found = true;
					case IrOpcode.Call:
						forwards(body.symbol(row).name, row, 0, 0);
					case IrOpcode.MethodCall:
						for (callee in methodTargets(body.valueType(body.operand(row, 0)), body.symbol(row).name))
							forwards(callee, row, 1, 1);
					case _:
				}
				row = body.nextRow(row);
			}
		}
		// Each argument is explored once per search, even through recursive forwarding graphs.
		// Only root negatives are complete; a nested search may have skipped an active caller.
		if (found || root)
			invoked.set(key, found);
		return found;
	}

	/** Preserve possible closure origins through SSA aliases and joins. */
	static function propagate(body:IrBody, origins:Map<Int, Array<String>>):Void {
		var fields:Map<String, Array<String>> = [];
		// Adds the origins of `input` to those of `output`.
		function flow(input:Int, output:Int):Bool {
			var changed = false;
			if (origins.exists(input))
				for (origin in origins.get(input)) {
					if (!origins.exists(output))
						origins.set(output, []);
					if (!origins.get(output).contains(origin)) {
						origins.get(output).push(origin);
						changed = true;
					}
				}
			return changed;
		}
		var changed = true;
		while (changed) {
			changed = false;
			for (block in 0...body.blockCount()) {
				var row = body.firstRow(block);
				while (row >= 0) {
					var opcode = body.opcode(row), output:Int = body.output(row);
					if (opcode == IrOpcode.FieldSet && origins.exists(body.operand(row, 1))) {
						var key = (body.operand(row, 0):Int) + ":" + body.symbol(row).name;
						if (!fields.exists(key))
							fields.set(key, []);
						for (origin in origins.get(body.operand(row, 1)))
							if (!fields.get(key).contains(origin)) {
								fields.get(key).push(origin);
								changed = true;
							}
					}
					if (output >= 0) {
						if (opcode == IrOpcode.FieldGet) {
							var key = (body.operand(row, 0):Int) + ":" + body.symbol(row).name;
							if (fields.exists(key)) {
								if (!origins.exists(output))
									origins.set(output, []);
								for (origin in fields.get(key))
									if (!origins.get(output).contains(origin)) {
										origins.get(output).push(origin);
										changed = true;
									}
							}
						}
						switch opcode {
							case IrOpcode.SafeCast, IrOpcode.ToDyn, IrOpcode.ToVirtual, IrOpcode.Upcast:
								if (flow(body.operand(row, 0), output))
									changed = true;
							case IrOpcode.Phi:
								for (index in 0...body.operandCount(row))
									if (flow(body.operand(row, index), output))
										changed = true;
							case _:
						}
					}
					row = body.nextRow(row);
				}
			}
		}
	}
}
