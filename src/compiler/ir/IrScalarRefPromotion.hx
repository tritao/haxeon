package compiler.ir;

import compiler.ir.Ir;
import compiler.ir.IrFunction.IrDebugBinding;
import compiler.ir.SourceProvenance.Located;

/**
 * Turns HashLink scalar references that never leave their function back into values.
 *
 * A struct result returned through scalar out parameters (`IrScalarArguments`) is a reference the caller makes
 * (`IrHlScalarRef.ADDRESS`), the callee stores (`STORE`) and the caller loads (`LOAD`). Once the callee is inlined, all
 * three are in one function, usually one block, and the reference only moves a value from a store to a load. A reference
 * used by nothing but its stores and loads, whose every load follows a store (or the reference's making) in its own
 * block, is removed: each load becomes the value stored last, and the reference, its stores and loads go. A field of the
 * result nothing reads is then an unused value, which the dead value pass removes with what computed it.
 */
class IrScalarRefPromotion {
	public static function run(fn:IrFunction):IrFunction {
		// The value each reference starts with; most functions make none.
		var initial:Null<Map<Int, IrValue>> = null;
		for (block in fn.blocks)
			for (located in block.instructions)
				switch located.value {
					case Call(output, name, arguments) if (name.name == IrHlScalarRef.ADDRESS && arguments.length == 1):
						if (initial == null)
							initial = [];
						initial.set(output.id, arguments[0]);
					default:
				}
		if (initial == null)
			return fn;
		var references = initial;
		// A reference is kept when anything but its own stores and loads uses it.
		var kept:Map<Int, Bool> = [];
		inline function escape(value:IrValue):Void
			if (references.exists(value.id))
				kept.set(value.id, true);
		for (block in fn.blocks) {
			for (located in block.instructions)
				switch located.value {
					case Call(_, name, arguments) if (name.name == IrHlScalarRef.ADDRESS):
					case Call(_, name, arguments) if (name.name == IrHlScalarRef.STORE && arguments.length == 2):
						escape(arguments[1]);
					case Call(_, name, arguments) if (name.name == IrHlScalarRef.LOAD && arguments.length == 1):
					case Phi(_, inputs):
						for (input in inputs)
							escape(input.value);
					default:
						var instruction = located.value;
						for (operand in 0...IrOperands.count(instruction))
							escape(IrOperands.at(instruction, operand));
				}
			if (block.terminator != null)
				switch block.terminator.value {
					case Return(value), Throw(value), Rethrow(value), Branch(value, _, _), Switch(value, _, _):
						escape(value);
					case Jump(_), Unreachable:
				}
		}
		for (binding in fn.debugBindings)
			escape(binding.value);
		// Forward each block's stores to its loads; a load with nothing before it in its block keeps its reference.
		var replacements:Map<Int, IrValue> = [], changed = true;
		while (changed) {
			changed = false;
			replacements.clear();
			for (block in fn.blocks) {
				var current:Map<Int, IrValue> = [];
				for (located in block.instructions)
					switch located.value {
						case Call(output, name, arguments) if (name.name == IrHlScalarRef.ADDRESS
							&& !kept.exists(output.id)):
							current.set(output.id, arguments[0]);
						case Call(_, name, arguments) if (name.name == IrHlScalarRef.STORE && arguments.length == 2
							&& references.exists(arguments[0].id) && !kept.exists(arguments[0].id)):
							current.set(arguments[0].id, arguments[1]);
						case Call(output, name, arguments) if (name.name == IrHlScalarRef.LOAD && arguments.length == 1
							&& references.exists(arguments[0].id) && !kept.exists(arguments[0].id)):
							var stored = current.get(arguments[0].id);
							if (stored == null) {
								kept.set(arguments[0].id, true);
								changed = true;
							} else
								replacements.set(output.id, stored);
						default:
					}
			}
		}
		var promoted = false;
		for (id in references.keys())
			if (!kept.exists(id))
				promoted = true;
		if (!promoted)
			return fn;
		function find(value:IrValue):IrValue {
			var current = value;
			while (true) {
				var next = replacements.get(current.id);
				if (next == null)
					return current;
				current = next;
			}
		}
		function removed(instruction:IrInstruction):Bool
			return switch instruction {
				case Call(output, name, _) if (name.name == IrHlScalarRef.ADDRESS): !kept.exists(output.id);
				case Call(_, name, arguments) if ((name.name == IrHlScalarRef.STORE || name.name == IrHlScalarRef.LOAD)
					&& arguments.length >= 1 && references.exists(arguments[0].id)):
					!kept.exists(arguments[0].id);
				default: false;
			};
		var blocks:Array<IrBlock> = [];
		for (block in fn.blocks) {
			var copy = new IrBlock(block.id);
			for (located in block.instructions)
				if (!removed(located.value))
					copy.instructions.push(new Located(IrInliner.remap(located.value, find, id -> id),
						located.provenance));
			var terminator = block.terminator;
			if (terminator != null)
				copy.terminator = new Located(switch terminator.value {
					case Return(value): Return(find(value));
					case Throw(value): Throw(find(value));
					case Rethrow(value): Rethrow(find(value));
					case Branch(condition, yes, no): Branch(find(condition), yes, no);
					case Switch(value, targets, otherwise): Switch(find(value), targets, otherwise);
					case other: other;
				}, terminator.provenance);
			blocks.push(copy);
		}
		var bindings:Array<IrDebugBinding> = [for (binding in fn.debugBindings) {
			identity:binding.identity,
				name:binding.name,
				value:find(binding.value),
				path:binding.path,
				scopeStart:binding.scopeStart,
				scopeEnd:binding.scopeEnd
		}];
		return fn.withBlocks(blocks, bindings);
	}

	/** Whether `row` calls the function named `symbol` (an `IrSymbol` id) with `arguments` operands, or any number when -1. */
	static inline function calls(body:IrBody, row:Int, symbol:Int, arguments:Int):Bool
		return body.opcode(row) == IrOpcode.Call && body.aux(row) == symbol
			&& (arguments < 0 || body.operandCount(row) == arguments);

	/** `run` on a body, in place; whether it changed the body. */
	public static function runBody(body:IrBody, scratch:IrPassScratch):Bool {
		var address = IrSymbol.of(IrHlScalarRef.ADDRESS).id,
			store = IrSymbol.of(IrHlScalarRef.STORE).id,
			load = IrSymbol.of(IrHlScalarRef.LOAD).id;
		// By value id: 1 for a reference (an address made here), and 1 for a reference kept (used other than by its own stores
		// and loads, or loaded where nothing was stored in its block before).
		var references:Null<Array<Int>> = null;
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				if (calls(body, row, address, 1)) {
					if (references == null)
						references = IrPassScratch.filledInts(scratch.firstInts, body.valueLimit(), 0);
					references[body.output(row)] = 1;
				}
				row = body.nextRow(row);
			}
		}
		if (references == null)
			return false;
		var kept = IrPassScratch.filledInts(scratch.secondInts, body.valueLimit(), 0);
		inline function isReference(value:IrValueId):Bool
			return references[value] == 1;
		inline function escape(value:IrValueId):Void
			if (isReference(value))
				kept[value] = 1;
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				if (calls(body, row, store, 2))
					escape(body.operand(row, 1));
				else if (!calls(body, row, address, -1) && !calls(body, row, load, 1))
					for (index in 0...body.operandCount(row))
						escape(body.operand(row, index));
				row = body.nextRow(row);
			}
		}
		for (index in 0...body.bindingCount())
			escape(body.bindingValue(index));
		// Forward each block's stores to its loads; a load with nothing before it in its block keeps its reference. Replacements
		// are pairs (load, value); the value stored in a block, by reference, is valid while the reference is marked.
		var replacements = scratch.firstTuples,
			current = IrPassScratch.filledInts(scratch.thirdInts, body.valueLimit(), -1),
			stored = scratch.marked,
			changed = true;
		while (changed) {
			changed = false;
			replacements.resize(0);
			for (block in 0...body.blockCount()) {
				stored.clear();
				var row = body.firstRow(block);
				while (row >= 0) {
					if (calls(body, row, address, -1)) {
						var output = body.output(row);
						if (kept[output] == 0 && body.operandCount(row) > 0) {
							stored.add(output);
							current[output] = body.operand(row, 0);
						}
					} else if (calls(body, row, store, 2)) {
						var reference = body.operand(row, 0);
						if (isReference(reference) && kept[reference] == 0) {
							stored.add(reference);
							current[reference] = body.operand(row, 1);
						}
					} else if (calls(body, row, load, 1)) {
						var reference = body.operand(row, 0);
						if (isReference(reference) && kept[reference] == 0) {
							if (!stored.has(reference)) {
								kept[reference] = 1;
								changed = true;
							} else {
								replacements.push(body.output(row));
								replacements.push(current[reference]);
							}
						}
					}
					row = body.nextRow(row);
				}
			}
		}
		var promoted = false;
		for (value in 0...body.valueLimit())
			if (references[value] == 1 && kept[value] == 0)
				promoted = true;
		if (!promoted)
			return false;
		var pair = 0;
		while (pair < replacements.length) {
			body.alias(IrValueId.of(replacements[pair]), IrValueId.of(replacements[pair + 1]));
			pair += 2;
		}
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				var next = body.nextRow(row);
				if (calls(body, row, address, -1) && kept[body.output(row)] == 0
					|| (calls(body, row, store, -1) || calls(body, row, load, -1)) && body.operandCount(row) >= 1
					&& isReference(body.operand(row, 0)) && kept[body.operand(row, 0)] == 0)
					body.removeRow(block, row);
				row = next;
			}
		}
		body.sweepAliases();
		return true;
	}
}
