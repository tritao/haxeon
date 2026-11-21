package compiler.ir;

import compiler.core.InternalError;
import compiler.ir.Ir;

/** Lower typed value-array range operations directly to the lane runtime, on a body edited in place. */
class IrValueArrayRangeRewrite {
	/** Whether `body` changed; `uses` is a table this reuses. */
	public static function rewriteBody(body:IrBody, element:IrType, factory:IrValueArrayFactory, uses:Array<Int>):Bool {
		var arrayType = body.typeId(Array(element)), counted = false, changed = false;
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				var following = body.nextRow(row);
				if (body.opcode(row) == IrOpcode.Call) {
					var name = body.symbol(row).name;
					if ((name == "__array_copy_ref" || name == "__array_slice_ref" || name == "__array_concat_ref")
						&& IrValueArrayRows.typed(body, body.output(row), arrayType)) {
						check(body, row, arrayType, rangeOperation(name));
						body.setAux(row, IrSymbol.of(factory.rangeNativeName(rangeOperation(name))).id);
						changed = true;
					} else if ((name == "__array_copy_any" || name == "__array_slice_any"
						|| name == "__array_concat_any")
						&& body.operandCount(row) > 0
						&& IrValueArrayRows.typed(body, body.operand(row, 0), arrayType)) {
						var boxing = IrValueArrayRows.nextInstruction(body, row),
							conversion = boxing < 0 ? -1 : IrValueArrayRows.nextInstruction(body, boxing);
						if (conversion >= 0
							&& body.opcode(boxing) == IrOpcode.ToDyn
							&& body.opcode(conversion) == IrOpcode.SafeCast
							&& body.operand(boxing, 0) == body.output(row)
							&& body.operand(conversion, 0) == body.output(boxing)
							&& IrValueArrayRows.typed(body, body.output(conversion), arrayType)) {
							if (!counted) {
								IrValueArrayRows.countUses(body, uses);
								counted = true;
							}
							if (uses[body.output(row)] != 1 || uses[body.output(boxing)] != 1)
								throw new InternalError("Checked array range intermediate escapes");
							var operation = rangeOperation(name);
							check(body, row, arrayType, operation);
							following = body.nextRow(conversion);
							body.removeRow(block, conversion);
							body.removeRow(block, boxing);
							IrValueArrayRows.replaceByCall(body, block, row, body.output(conversion),
								factory.rangeNativeName(operation));
							changed = true;
						}
					}
				}
				row = following;
			}
		}
		return changed;
	}

	/** Checks the operands of range call `row`. */
	static function check(body:IrBody, row:Int, arrayType:Int, operation:String):Void {
		var arity = operation == "copy" ? 1 : operation == "slice" ? 3 : 2;
		if (body.operandCount(row) != arity
			|| !IrValueArrayRows.typed(body, body.operand(row, 0), arrayType)
			|| (operation == "concat" && !IrValueArrayRows.typed(body, body.operand(row, 1), arrayType)))
			throw new InternalError('Invalid inline array $operation operands');
	}

	static function rangeOperation(name:String):String {
		if (StringTools.startsWith(name, "__array_copy_"))
			return "copy";
		if (StringTools.startsWith(name, "__array_slice_"))
			return "slice";
		return "concat";
	}
}
