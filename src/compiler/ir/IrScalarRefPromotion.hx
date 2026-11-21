package compiler.ir;

import compiler.ir.Ir;

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
	/** Whether `row` calls the function named `symbol` (an `IrSymbol` id) with `arguments` operands, or any number when -1. */
	static inline function calls(body:IrBody, row:Int, symbol:Int, arguments:Int):Bool
		return body.opcode(row) == IrOpcode.Call && body.aux(row) == symbol
			&& (arguments < 0 || body.operandCount(row) == arguments);

	/** On a body, in place; whether it changed the body. */
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
