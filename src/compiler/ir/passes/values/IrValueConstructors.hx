package compiler.ir.passes.values;

import compiler.core.InternalError;
import compiler.ir.model.Ir;
import compiler.ir.model.IrBody;
import compiler.ir.model.IrFunction;
import compiler.ir.model.IrOpcode;
import compiler.ir.model.IrPassScratch;
import compiler.ir.model.IrTypeIds;

/**
 * Expand bounded value constructors so newly constructed places can remain scalar. On IR bodies (docs/design/IR_CORE_COLUMNS.md,
 * migration): a straight-line constructor's rows are copied in place of its call, a branching one is expanded as the inliner
 * expands a call (`IrBodyCallExpansion`).
 */
class IrValueConstructors {
	final scratch:IrPassScratch;

	/** By callee value id, its value in the body a straight-line constructor is copied into. */
	final calleeValues:Array<Int> = [];

	/**
	 * Expands `program`'s value constructor calls, on bodies made with `types` (those of the program's bodies when not given,
	 * `IrTypeIds.ofFunctions`). A function that changes becomes its
	 * edited body, owned by the next stage: edited in place, or a copy when a cache holds the body.
	 */
	public static function rewrite(program:IrProgram, ?types:IrTypeIds, ?scratch:IrPassScratch):Void {
		if (types == null)
			types = IrTypeIds.ofFunctions(program.functions);
		new IrValueConstructors(scratch == null ? new IrPassScratch() : scratch).run(program, types);
	}

	function new(scratch:IrPassScratch)
		this.scratch = scratch;

	function run(program:IrProgram, types:IrTypeIds):Void {
		var builder = scratch.bodyBuilder;
		var bodies = [for (fn in program.functions) fn.bodyIn(types, builder)];
		var objects:Map<String, IrObject> = [for (object in program.objects) object.name => object];
		// Callees are frozen, or copies: the functions they were made from are edited in place below.
		var constructors:Map<String, IrBody> = [],
			straight:Map<String, IrBody> = [];
		for (body in bodies) {
			var owner = switch body.types.type(body.result) {
				case Obj(name): objects.get(name);
				default: null;
			};
			if (owner == null || !owner.isValue || body.name != owner.name + ".new" || body.blockCount() == 0
				|| body.blockCount() > 16)
				continue;
			var safe = true, count = 0;
			for (block in 0...body.blockCount()) {
				var row = body.firstRow(block);
				while (row >= 0) {
					switch body.opcode(row) {
						case IrOpcode.Phi if (body.blockCount() == 1):
							safe = false;
						case IrOpcode.BeginTry | IrOpcode.EndTry | IrOpcode.Catch:
							safe = false;
						default:
					}
					if (!body.opcode(row).isTerminator())
						count++;
					row = body.nextRow(row);
				}
			}
			if (safe && count <= 64) {
				if (body.blockCount() == 1) {
					var terminator = body.terminatorRow(0);
					if (terminator >= 0 && body.opcode(terminator) == IrOpcode.Return)
						straight.set(body.name, snapshot(body));
				} else
					constructors.set(body.name, snapshot(body));
			}
		}
		// Prepare nested straight-line bodies first. Expanding only the caller once leaves constructor calls
		// introduced by an outer constructor boxed even when the complete value never escapes.
		var prepared = prepareStraightLine(straight),
			branches:Map<String, IrBody> = [];
		for (name => body in constructors)
			branches.set(name, expandStraightLine(body, prepared, true));
		program.functions = [for (index in 0...bodies.length) {
			var source = bodies[index],
				body = expand(expandStraightLine(source, prepared, false), branches);
			body == source ? program.functions[index] : IrFunction.ofOwnedBody(body);
		}];
	}

	/** `body`, or a copy of it when it is not frozen. */
	function snapshot(body:IrBody):IrBody
		return body.frozen ? body : body.thaw(scratch.bodyBuilder);

	/** Expand acyclic nested constructor bodies once, with a size bound to avoid exponential code growth. */
	function prepareStraightLine(constructors:Map<String, IrBody>):Map<String, IrBody> {
		var prepared:Map<String, IrBody> = [],
			visiting:Map<String, Bool> = [];
		function prepare(name:String):Null<IrBody> {
			if (prepared.exists(name))
				return prepared.get(name);
			if (visiting.exists(name))
				return null;
			var body = constructors.get(name);
			if (body == null)
				return null;
			visiting.set(name, true);
			var children:Map<String, IrBody> = [];
			for (block in 0...body.blockCount()) {
				var row = body.firstRow(block);
				while (row >= 0) {
					if (body.opcode(row) == IrOpcode.Call) {
						var child = body.symbol(row).name;
						if (child != name && constructors.exists(child)) {
							var nested = prepare(child);
							if (nested != null)
								children.set(child, nested);
						}
					}
					row = body.nextRow(row);
				}
			}
			var result = expandStraightLine(body, children, true);
			if (result.instructionCount() > 256)
				result = body;
			visiting.remove(name);
			prepared.set(name, result);
			return result;
		}
		var names = [for (name in constructors.keys()) name];
		names.sort(Reflect.compare);
		for (name in names)
			prepare(name);
		return prepared;
	}

	/** A call row of `body` to one of `constructors` other than itself: the constructor, or null. */
	static function constructorCall(body:IrBody, row:Int, constructors:Map<String, IrBody>):Null<IrBody> {
		if (body.opcode(row) != IrOpcode.Call)
			return null;
		var name = body.symbol(row).name;
		return name != body.name ? constructors.get(name) : null;
	}

	/**
	 * `body` with each call of a branching constructor of `constructors` expanded, the continuation after each visited next: on
	 * `body` itself when no cache holds it, else on a copy; `body` when there is none.
	 */
	function expand(body:IrBody, constructors:Map<String, IrBody>):IrBody {
		var found = false;
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0 && !found) {
				if (constructorCall(body, row, constructors) != null)
					found = true;
				row = body.nextRow(row);
			}
			if (found)
				break;
		}
		if (!found)
			return body;
		var edited = body.forEditing(scratch.bodyBuilder), nextBlock = 0;
		for (block in 0...edited.blockCount())
			if (edited.blockId(block) >= nextBlock)
				nextBlock = edited.blockId(block) + 1;
		var index = 0, changes = 0;
		while (index < edited.blockCount()) {
			var call = -1, callee:Null<IrBody> = null, row = edited.firstRow(index);
			while (row >= 0) {
				var target = constructorCall(edited, row, constructors);
				if (target != null && edited.operandCount(row) == target.argumentCount()) {
					call = row;
					callee = target;
					break;
				}
				row = edited.nextRow(row);
			}
			if (callee == null) {
				index++;
				continue;
			}
			nextBlock = scratch.callExpansion.expand(edited, index, call, callee, nextBlock, false);
			changes++;
			// Visit the continuation, not the cloned callee: recursive constructors
			// stay calls, while every independent call site can be expanded.
			index += callee.blockCount() + 1;
		}
		return changes == 0 ? body : edited;
	}

	/**
	 * `body` with each call of a straight-line constructor of `constructors` replaced by the constructor's rows: on a copy when
	 * `copy` or when a cache holds `body`, else on `body` itself; `body` when there is none.
	 */
	function expandStraightLine(body:IrBody, constructors:Map<String, IrBody>, copy:Bool):IrBody {
		var found = false;
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0 && !found) {
				var callee = constructorCall(body, row, constructors);
				if (callee != null && straightLineResult(callee, body.operandCount(row)) >= 0)
					found = true;
				row = body.nextRow(row);
			}
			if (found)
				break;
		}
		if (!found)
			return body;
		var edited = copy ? body.thaw(scratch.bodyBuilder) : body.forEditing(scratch.bodyBuilder);
		for (block in 0...edited.blockCount()) {
			var row = edited.firstRow(block);
			while (row >= 0) {
				var following = edited.nextRow(row), callee = constructorCall(edited, row, constructors);
				if (callee != null) {
					var returned = straightLineResult(callee, edited.operandCount(row));
					if (returned >= 0)
						copyStraightLine(edited, block, row, callee, returned);
				}
				row = following;
			}
		}
		return edited;
	}

	/**
	 * Replaces the call at `row` of block `block` (an index) by the rows of the straight-line `callee`: its arguments are the call's
	 * operands, the value it returns (`returned`) is the call's output, and its other values new ones.
	 */
	function copyStraightLine(body:IrBody, block:Int, row:Int, callee:IrBody, returned:Int):Void {
		var values = IrPassScratch.filledInts(calleeValues, callee.valueLimit(), -1), out = body.output(row);
		for (index in 0...callee.argumentCount())
			values[callee.argument(index)] = body.operand(row, index);
		var terminator = callee.terminatorRow(0), source = callee.firstRow(0);
		while (source >= 0 && source != terminator) {
			var result = callee.output(source);
			if (result.exists())
				values[result] = (result:Int) == returned ? out : body.newValue(callee.valueName(result),
					callee.valueTypeId(result));
			for (index in 0...callee.operandCount(source)) {
				var operand = callee.operand(source, index);
				if ((operand:Int) >= values.length || values[operand] < 0)
					throw new InternalError('Missing value constructor operand $operand');
			}
			body.linkBefore(block, row, body.copyRow(callee, source, values));
			source = callee.nextRow(source);
		}
		body.removeRow(block, row);
	}

	/**
	 * The value a straight-line constructor called with `arguments` operands returns, when a row of its block defines it, else -1:
	 * it cannot be expanded.
	 */
	static function straightLineResult(callee:IrBody, arguments:Int):Int {
		if (arguments != callee.argumentCount())
			return -1;
		var terminator = callee.terminatorRow(0);
		if (terminator < 0 || callee.opcode(terminator) != IrOpcode.Return)
			return -1;
		var returned = callee.operand(terminator, 0), row = callee.firstRow(0);
		while (row >= 0) {
			if (row != terminator && (callee.output(row):Int) == (returned:Int))
				return returned;
			row = callee.nextRow(row);
		}
		return -1;
	}
}
