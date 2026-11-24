package compiler.ir.passes.arrays;

import compiler.ir.model.Ir;
import compiler.ir.model.IrBody;
import compiler.ir.model.IrBodyBuilder;
import compiler.ir.model.IrFunction;
import compiler.ir.model.IrOpcode;
import compiler.ir.model.IrPassScratch;
import compiler.ir.model.IrSymbol;
import compiler.ir.model.IrValueId;
import compiler.ir.model.SourceProvenance;

/** Row reads and edits the value-array rewrites share, on IR bodies edited in place. */
@:nullSafety(Strict)
class IrValueArrayRows {
	/** How many operands of linked rows read each value, in `table` (reused): phi inputs and terminators included. */
	public static function countUses(body:IrBody, table:Array<Int>):Array<Int> {
		var uses = IrPassScratch.filledInts(table, body.valueLimit(), 0);
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				for (index in 0...body.operandCount(row))
					uses[body.operand(row, index)]++;
				row = body.nextRow(row);
			}
		}
		return uses;
	}

	/** Makes the `Call` of `name` begun with `beginRow` and its operands, linked before `before` in block `block` (an index). */
	public static function linkCall(body:IrBody, block:Int, before:Int, output:IrValueId, name:String,
			where:SourceProvenance):Int {
		var row = body.endRow(IrOpcode.Call, output, IrSymbol.of(name).id, where);
		body.linkBefore(block, before, row);
		return row;
	}

	/** Links a `Call` of `name` with operands `first` and `second` before `before`. */
	public static function call2(body:IrBody, block:Int, before:Int, output:IrValueId, name:String, first:IrValueId,
			second:IrValueId, where:SourceProvenance):Int {
		body.beginRow();
		body.pushOperand(first);
		body.pushOperand(second);
		return linkCall(body, block, before, output, name, where);
	}

	/** Links a `Call` of `name` with operands `first`, `second` and `third` before `before`. */
	public static function call3(body:IrBody, block:Int, before:Int, output:IrValueId, name:String, first:IrValueId,
			second:IrValueId, third:IrValueId, where:SourceProvenance):Int {
		body.beginRow();
		body.pushOperand(first);
		body.pushOperand(second);
		body.pushOperand(third);
		return linkCall(body, block, before, output, name, where);
	}

	/** Replaces `row` by a `Call` of `name` defining `output`, with the row's operands. */
	public static function replaceByCall(body:IrBody, block:Int, row:Int, output:IrValueId, name:String):Int {
		if (output == body.output(row)) {
			body.setOperation(row, IrOpcode.Call, IrSymbol.of(name).id);
			return row;
		}
		body.beginRow();
		for (index in 0...body.operandCount(row))
			body.pushOperand(body.operand(row, index));
		var made = linkCall(body, block, row, output, name, body.provenance(row));
		body.removeRow(block, row);
		return made;
	}

	/** Links a `ConstBool` before `before`. */
	public static function constBool(body:IrBody, block:Int, before:Int, output:IrValueId, state:Bool,
			where:SourceProvenance):Void {
		body.beginRow();
		body.linkBefore(block, before, body.endRow(IrOpcode.ConstBool, output, state ? 1 : 0, where));
	}

	/** The row after `row` in its block when it is no terminator, else -1. */
	public static inline function nextInstruction(body:IrBody, row:Int):Int {
		var next = body.nextRow(row);
		return next >= 0 && !body.opcode(next).isTerminator() ? next : -1;
	}

	/** Whether `body`'s value `value` has type `typeId`. */
	public static inline function typed(body:IrBody, value:IrValueId, typeId:Int):Bool
		return body.valueTypeId(value) == typeId;

	/** Removes the debug bindings whose value `drop` names. */
	public static function removeBindings(body:IrBody, drop:Int->Bool):Void {
		var index = 0;
		while (index < body.bindingCount())
			if (drop(body.bindingValue(index)))
				body.removeBinding(index);
			else
				index++;
	}

	/**
	 * A function's body for a rewrite that changes it on a copy (`IrBodyBuilder.encode` or a thawed copy of the body it has), so
	 * the function stays as it was: for a pass run on its own (a test).
	 */
	public static function standaloneBody(fn:IrFunction):IrBody {
		var body = fn.body;
		return body != null ? body.thaw() : IrBodyBuilder.encode(fn);
	}
}
