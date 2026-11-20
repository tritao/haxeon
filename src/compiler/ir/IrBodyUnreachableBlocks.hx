package compiler.ir;

/** `IrUnreachableBlocks` on bodies, with the same results; the same body when nothing is unreachable. */
class IrBodyUnreachableBlocks {
	public static function remove(body:IrBody, scratch:IrPassScratch):IrBody {
		var count = body.blockCount(), size = 0;
		for (block in 0...count)
			if (body.blockId(block) >= size)
				size = body.blockId(block) + 1;
		// By block id: its index (-1 for none), and whether the entry reaches it (1).
		var indices = IrPassScratch.filledInts(scratch.firstInts, size, -1),
			reached = IrPassScratch.filledInts(scratch.secondInts, size, 0),
			work = scratch.pendingIds;
		for (block in 0...count)
			indices[body.blockId(block)] = block;
		work.resize(0);
		reached[body.blockId(0)] = 1;
		work.push(body.blockId(0));
		while (work.length > 0) {
			var id = work[work.length - 1];
			work.resize(work.length - 1);
			var block = id >= 0 && id < size ? indices[id] : -1;
			if (block < 0)
				continue;
			forEachEdge(body, block, target -> {
				if (target >= 0 && target < size && reached[target] == 0) {
					reached[target] = 1;
					work.push(target);
				}
			});
		}
		inline function isReached(id:Int):Bool
			return id >= 0 && id < size && reached[id] == 1;
		function flows(from:Int, to:Int):Bool {
			if (!isReached(from) || indices[from] < 0)
				return false;
			var found = false;
			forEachEdge(body, indices[from], target -> {
				if (target == to)
					found = true;
			});
			return found;
		}
		var changed = false;
		for (block in 0...count) {
			var id = body.blockId(block);
			if (!isReached(id))
				changed = true;
			else
				for (row in body.firstRow(block)...body.instructionEnd(block))
					if (body.opcode(row) == IrOpcode.Phi)
						for (index in 0...body.operandCount(row))
							if (!flows(body.auxInt(row, index), id))
								changed = true;
		}
		if (!changed)
			return body;
		var removed = scratch.marked, builder = scratch.bodyBuilder;
		removed.clear();
		builder.startFrom(body);
		for (block in 0...count) {
			var id = body.blockId(block);
			if (!isReached(id)) {
				for (row in body.firstRow(block)...body.instructionEnd(block))
					if (body.output(row) >= 0)
						removed.add(body.output(row));
				continue;
			}
			builder.beginBlock(id);
			for (row in body.firstRow(block)...body.endRow(block))
				if (body.opcode(row) == IrOpcode.Phi) {
					var start = builder.poolStart();
					for (index in 0...body.operandCount(row))
						if (flows(body.auxInt(row, index), id)) {
							builder.operandId(body.operand(row, index));
							builder.int(body.auxInt(row, index));
						}
					builder.row(IrOpcode.Phi, body.output(row), start, body.provenance(row));
				} else
					builder.copyRow(body, row);
		}
		for (index in 0...body.bindingCount())
			if (!removed.has(body.bindingValue(index)))
				builder.copyBinding(body, index, body.bindingValue(index));
		return builder.finishFrom(body);
	}

	/** `IrUnreachableBlocks.edges`: each try region's handler and after block, then the terminator's distinct targets. */
	static inline function forEachEdge(body:IrBody, block:Int, visit:Int->Void):Void {
		for (row in body.firstRow(block)...body.instructionEnd(block))
			switch body.opcode(row) {
				case IrOpcode.BeginTry:
					visit(body.auxInt(row, 0));
					visit(body.auxInt(row, 1));
				case IrOpcode.EndTry:
					visit(body.auxInt(row, 0));
				default:
			}
		var terminator = body.terminatorRow(block);
		if (terminator >= 0)
			for (index in 0...body.successorCount(terminator))
				visit(body.successor(terminator, index));
	}
}
