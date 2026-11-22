package compiler.ir.analysis;

import compiler.core.InternalError;
import compiler.ir.model.Ir;
import compiler.ir.model.IrBody;
import compiler.ir.model.IrBodyBuilder;
import compiler.ir.model.IrFunction;
import compiler.ir.model.IrOpcode;
import compiler.ir.model.IrTypeIds;

/** Calls that can execute while evaluating a function, excluding callbacks only stored for later. */
/**
 * Calls that can execute while evaluating a function, excluding callbacks only stored for later. Reads the functions' bodies
 * (docs/design/IR_CORE_COLUMNS.md).
 */
@:nullSafety(Strict)
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

	/** `program` read as its bodies made with `types`, encoding a function that has none. */
	public function new(program:Array<IrFunction>, types:IrTypeIds, ?objects:Array<IrObject>, ?builder:IrBodyBuilder) {
		this.objects = objects == null ? [] : [for (object in objects) object.name => object];
		objectList = objects == null ? [] : objects;
		var listed = [for (fn in program) fn.bodyIn(types, builder)];
		bodies = [for (index in 0...program.length) program[index].name => listed[index]];
		for (fn in program) {
			var dot = fn.name.lastIndexOf(".");
			if (dot < 0)
				continue;
			var method = fn.name.substr(dot + 1), named = methods.get(method);
			if (named == null)
				methods.set(method, named = []);
			named.push(fn.name);
		}
		var summaries:Array<IrBody> = [];
		for (index in 0...program.length) {
			var fn = program[index], body = listed[index];
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
							case IrOpcode.GlobalSet:
								var stored = origins.get(body.operand(row, 0));
								if (stored != null && merge(globals, body.symbol(row).name, stored))
									changed = true;
							case IrOpcode.Return:
								var returned = origins.get(body.operand(row, 0));
								if (returned != null && merge(returns, body.name, returned))
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
		var merged = target.get(key);
		if (merged == null)
			target.set(key, merged = []);
		var changed = false;
		for (value in values)
			if (!merged.contains(value)) {
				merged.push(value);
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
					case IrOpcode.GlobalGet:
						var stored = globals.get(body.symbol(row).name);
						if (stored != null)
							origins.set(out, stored.copy());
					case IrOpcode.Call:
						var returned = returns.get(body.symbol(row).name);
						if (returned != null)
							origins.set(out, returned.copy());
					case IrOpcode.MethodCall:
						var found:Array<String> = [];
						for (callee in methodTargets(body.valueType(body.operand(row, 0)), body.symbol(row).name)) {
							var returned = returns.get(callee);
							if (returned != null)
								found = found.concat(returned);
						}
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
		var found = bodies.get(name);
		if (found == null)
			throw new InternalError('"$name" is not a function of the program');
		var body:IrBody = found;
		var result:Array<String> = [], closures = closureOrigins(body);
		// The callbacks among the operands from `first` on, the callee's arguments from `offset` on.
		function addCallbacks(callee:String, row:Int, first:Int, offset:Int):Void {
			for (index in first...body.operandCount(row)) {
				var targets = closures.get(body.operand(row, index));
				if (targets != null && invokesArgument(callee, index - first + offset, []))
					for (target in targets)
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
						var targets = closures.get(body.operand(row, 0));
						if (targets != null)
							result = result.concat(targets);
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
			return methods.get(method) ?? [];
		var key = owner + "." + method, known = resolvedMethods.get(key);
		if (known != null)
			return known;
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
		var key = name + ":" + index, known = invoked.get(key);
		if (known != null)
			return known;
		var named = bodies.get(name);
		if (named == null || seen.exists(key))
			return false;
		var body:IrBody = named;
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
			var changed = false, from = origins.get(input);
			if (from != null)
				for (origin in from) {
					var to = origins.get(output);
					if (to == null)
						origins.set(output, to = []);
					if (!to.contains(origin)) {
						to.push(origin);
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
					var stored = opcode == IrOpcode.FieldSet ? origins.get(body.operand(row, 1)) : null;
					if (stored != null) {
						var key = (body.operand(row, 0):Int) + ":" + body.symbol(row).name, field = fields.get(key);
						if (field == null)
							fields.set(key, field = []);
						for (origin in stored)
							if (!field.contains(origin)) {
								field.push(origin);
								changed = true;
							}
					}
					if (output >= 0) {
						if (opcode == IrOpcode.FieldGet) {
							var field = fields.get((body.operand(row, 0):Int) + ":" + body.symbol(row).name);
							if (field != null) {
								var to = origins.get(output);
								if (to == null)
									origins.set(output, to = []);
								for (origin in field)
									if (!to.contains(origin)) {
										to.push(origin);
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
