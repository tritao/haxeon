package compiler.ir;

import compiler.core.InternalError;
import compiler.ir.Ir;

/**
 * Inlining one call of a body in place by a copy of a branching callee (`expand`), and binding a callee's parameters to a call's
 * operands: the inliner's, which value constructors share. One serves many expansions; its tables are reused.
 */
class IrBodyCallExpansion {
	/** The tables of one expansion: by callee value id its value here, by callee block id its block id here. */
	final calleeValues:Array<Int> = [];

	final calleeBlocks:Array<Int> = [];

	/** The rows an expanded call puts before the callee's: its receiver check and upcasts. */
	final madeRows:Array<Int> = [];

	final successorIds:Array<Int> = [];
	final returnedValues:Array<Int> = [];
	final returnedBlocks:Array<Int> = [];

	public function new() {}

	/** Gives the callee row's output, when it has one, a new value of the caller. */
	public static inline function defineCalleeValue(body:IrBody, callee:IrBody, row:Int, values:Array<Int>):Void {
		var out = callee.output(row);
		if (out.exists())
			values[out] = body.newValue(callee.valueName(out), callee.valueTypeId(out));
	}

	public static function calleeValue(values:Array<Int>, value:IrValueId):IrValueId {
		var mapped = (value:Int) < values.length ? values[value] : -1;
		if (mapped < 0)
			throw new InternalError("Inliner found an undefined callee value");
		return IrValueId.of(mapped);
	}

	/**
	 * Binds the callee's parameters to the call's operands (resolved through the aliases when `resolved`). A call passes an
	 * object of a subclass where its parameter takes the base class; inlined, that value is upcast first (a row made in `rows`),
	 * so the body keeps the types it was verified with.
	 */
	public function bindArgumentValues(body:IrBody, call:Int, callee:IrBody, values:Array<Int>, rows:Array<Int>,
			where:SourceProvenance, resolved:Bool):Void {
		for (index in 0...callee.argumentCount()) {
			var formal = callee.argument(index), actual = body.operand(call, index);
			if (resolved)
				actual = body.resolve(actual);
			var formalType = callee.valueTypeId(formal), actualType = body.valueTypeId(actual);
			if (formalType == actualType
				|| IrVerifier.sameType(body.types.type(actualType), body.types.type(formalType)))
				values[formal] = actual;
			else {
				var upcast = body.newValue(callee.valueName(formal), formalType);
				body.beginRow();
				body.pushOperand(actual);
				rows.push(body.endRow(IrOpcode.Upcast, upcast, 0, where));
				values[formal] = upcast;
			}
		}
	}

	/**
	 * Replaces the call at row `call` of block `head` (an index) by a copy of the branching callee. The head keeps the rows
	 * before the call, then the receiver check and upcasts, and jumps into the copy, whose blocks follow it with new ids; a new
	 * continuation block merges the returned values with a phi and takes the rows after the call and the head's terminator.
	 * Gives the next free block id.
	 */
	public function expand(body:IrBody, head:Int, call:Int, callee:IrBody, nextBlock:Int, checkReceiver:Bool):Int {
		var voidType = body.typeId(Void);
		var where = body.provenance(call), output = body.output(call), headId = body.blockId(head), rows = madeRows;
		rows.resize(0);
		var values = IrPassScratch.filledInts(calleeValues, callee.valueLimit(), -1);
		if (checkReceiver) {
			var checked = body.newValue("$receiver-check", voidType);
			body.beginRow();
			body.pushOperand(body.operand(call, 0));
			rows.push(body.endRow(IrOpcode.Call, checked, IrSymbol.of(IrReceiverCheck.NAME).id, where));
		}
		bindArgumentValues(body, call, callee, values, rows, where, false);
		// Every definition first, so phis and back edges can refer to values defined later in block order.
		var blockLimit = 0;
		for (block in 0...callee.blockCount())
			if (callee.blockId(block) >= blockLimit)
				blockLimit = callee.blockId(block) + 1;
		var blocks = IrPassScratch.filledInts(calleeBlocks, blockLimit, -1);
		for (block in 0...callee.blockCount()) {
			blocks[callee.blockId(block)] = nextBlock++;
			var terminator = callee.terminatorRow(block), row = callee.firstRow(block);
			while (row >= 0 && row != terminator) {
				defineCalleeValue(body, callee, row, values);
				row = callee.nextRow(row);
			}
		}
		var continuation = nextBlock++;
		// Everything that used to leave the head will leave the continuation, so successor phis name the new predecessor.
		var headTerminator = body.terminatorRow(head);
		if (headTerminator < 0)
			throw new InternalError("Inliner found a call site without a terminator");
		var successors = successorIds;
		successors.resize(0);
		switch body.opcode(headTerminator) {
			case IrOpcode.Jump:
				successors.push(body.aux(headTerminator));
			case IrOpcode.Branch:
				successors.push(body.auxInt(headTerminator, 0));
				successors.push(body.auxInt(headTerminator, 1));
			default:
		}
		var row = body.nextRow(call);
		while (row >= 0) {
			if (body.opcode(row) == IrOpcode.BeginTry) {
				successors.push(body.auxInt(row, 0));
				successors.push(body.auxInt(row, 1));
			}
			row = body.nextRow(row);
		}
		for (block in 0...body.blockCount())
			if (successors.indexOf(body.blockId(block)) >= 0)
				retargetPhiInputs(body, block, block == head ? call : -1, headId, continuation);
		// The callee's blocks after the head, then the continuation.
		var count = callee.blockCount(), after = head + 1 + count;
		for (block in 0...count)
			body.addBlock(head + 1 + block, blocks[callee.blockId(block)]);
		body.addBlock(after, continuation);
		returnedValues.resize(0);
		returnedBlocks.resize(0);
		for (block in 0...count) {
			var into = head + 1 + block;
			if (callee.terminatorRow(block) < 0)
				throw new InternalError("Inliner found a callee block without a terminator");
			row = callee.firstRow(block);
			while (row >= 0) {
				if (callee.opcode(row) == IrOpcode.Return) {
					returnedBlocks.push(body.blockId(into));
					returnedValues.push(calleeValue(values, callee.operand(row, 0)));
					body.beginRow();
					body.linkBefore(into, -1,
						body.endRow(IrOpcode.Jump, IrValueId.of(-1), continuation, callee.provenance(row)));
				} else
					body.linkBefore(into, -1, body.copyRow(callee, row, values, blocks));
				row = callee.nextRow(row);
			}
		}
		// The continuation defines the call's output, then runs whatever followed the call.
		var tail = body.nextRow(call);
		body.removeRow(head, call);
		body.beginRow();
		var merge = if (body.valueTypeId(output) == voidType)
			body.endRow(IrOpcode.ConstVoid, output, 0, where);
		else {
			for (value in returnedValues)
				body.pushOperand(IrValueId.of(value));
			var start = body.pushInt(returnedBlocks[0]);
			for (index in 1...returnedBlocks.length)
				body.pushInt(returnedBlocks[index]);
			body.endRow(IrOpcode.Phi, output, start, where);
		}
		body.linkBefore(after, -1, merge);
		body.moveTail(head, tail, after);
		for (made in rows)
			body.linkBefore(head, -1, made);
		body.beginRow();
		body.linkBefore(head, -1, body.endRow(IrOpcode.Jump, IrValueId.of(-1), blocks[callee.blockId(0)], where));
		return nextBlock;
	}

	/** Makes every phi input of block `block` (an index) from block id `from` come from `to`, the rows before `stop` only. */
	static function retargetPhiInputs(body:IrBody, block:Int, stop:Int, from:Int, to:Int):Void {
		var row = body.firstRow(block);
		while (row >= 0 && row != stop) {
			if (body.opcode(row) == IrOpcode.Phi)
				for (index in 0...body.operandCount(row))
					if (body.auxInt(row, index) == from)
						body.setAuxInt(row, index, to);
			row = body.nextRow(row);
		}
	}
}
