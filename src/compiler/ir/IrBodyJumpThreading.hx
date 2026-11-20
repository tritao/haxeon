package compiler.ir;

private typedef BodyJumpBridge = {
	final predecessor:Int;
	final target:Int;
	final conditional:Bool;
}

/** `IrJumpThreading` on bodies, with the same results; the tables come from an `IrPassScratch`. */
class IrBodyJumpThreading {
	public static function run(body:IrBody, scratch:IrPassScratch):IrBody {
		var count = body.blockCount();
		if (count < 3)
			return body;
		var candidate = false;
		for (block in 0...count) {
			var terminator = body.terminatorRow(block);
			if (block != 0 && terminator >= 0 && terminator == body.firstRow(block)
				&& body.opcode(terminator) == IrOpcode.Jump)
				candidate = true;
			for (row in body.firstRow(block)...body.instructionEnd(block))
				switch body.opcode(row) {
					case IrOpcode.BeginTry, IrOpcode.EndTry, IrOpcode.Catch: return body;
					default:
				}
		}
		if (!candidate)
			return body;
		var graph = scratch.bodyGraph.reset(body), external:Map<Int, Bool> = [], bridges:Map<Int, BodyJumpBridge> = [];
		for (block in 0...count)
			if (!graph.isReachable(body.blockId(block))) {
				var terminator = body.terminatorRow(block);
				if (terminator >= 0)
					for (index in 0...body.successorCount(terminator))
						external.set(body.successor(terminator, index), true);
				for (row in body.firstRow(block)...body.instructionEnd(block))
					if (body.opcode(row) == IrOpcode.Phi)
						for (index in 0...body.operandCount(row))
							external.set(body.auxInt(row, index), true);
			}
		var entry = body.blockId(0);
		for (block in 0...count) {
			var id = body.blockId(block), terminator = body.terminatorRow(block);
			if (id == entry || terminator < 0 || terminator != body.firstRow(block) || !graph.isReachable(id)
				|| external.exists(id))
				continue;
			var target = body.opcode(terminator) == IrOpcode.Jump ? body.aux(terminator) : -1;
			if (target < 0 || target == id || !graph.contains(target))
				continue;
			if (graph.predecessorCount(id) != 1)
				continue;
			var only = graph.predecessor(id, 0);
			if (only == id || only == target)
				continue;
			var term = body.terminatorRow(graph.indexOf(only));
			if (term < 0)
				continue;
			switch body.opcode(term) {
				case IrOpcode.Jump: bridges.set(id, {predecessor: only, target: target, conditional: false});
				case IrOpcode.Branch, IrOpcode.Switch: bridges.set(id, {
					predecessor: only,
					target: target,
					conditional: true
				});
				default:
			}
		}
		for (id in [for (id in bridges.keys()) id])
			if (bridges.get(id).conditional && hasPhis(body, graph.indexOf(finalTarget(id, bridges))))
				bridges.remove(id);
		if (!bridges.keys().hasNext())
			return body;
		var builder = scratch.bodyBuilder;
		builder.startFrom(body);
		for (block in 0...count) {
			var id = body.blockId(block);
			if (bridges.exists(id))
				continue;
			builder.beginBlock(id);
			for (row in body.firstRow(block)...body.instructionEnd(block))
				if (body.opcode(row) == IrOpcode.Phi) {
					var start = builder.poolStart();
					for (index in 0...body.operandCount(row)) {
						builder.operandId(body.operand(row, index));
						builder.int(originalPredecessor(body.auxInt(row, index), bridges));
					}
					builder.row(IrOpcode.Phi, body.output(row), start, body.provenance(row));
				} else
					builder.copyRow(body, row);
			var terminator = body.terminatorRow(block);
			if (terminator >= 0)
				retargetTerminator(body, terminator, builder, target -> finalTarget(target, bridges));
		}
		for (index in 0...body.bindingCount())
			builder.copyBinding(body, index, body.bindingValue(index));
		return builder.finishFrom(body);
	}

	/** Copies a terminator row with each block it goes to renamed by `rename`. */
	static function retargetTerminator(body:IrBody, row:Int, builder:IrBodyBuilder, rename:Int->Int):Void {
		var where = body.provenance(row);
		switch body.opcode(row) {
			case IrOpcode.Jump:
				builder.row(IrOpcode.Jump, -1, rename(body.aux(row)), where);
			case IrOpcode.Branch:
				builder.operandId(body.operand(row, 0));
				var start = builder.int(rename(body.auxInt(row, 0)));
				builder.int(rename(body.auxInt(row, 1)));
				builder.row(IrOpcode.Branch, -1, start, where);
			case IrOpcode.Switch:
				builder.operandId(body.operand(row, 0));
				var targets = body.auxInt(row, 1), start = builder.int(rename(body.auxInt(row, 0)));
				builder.int(targets);
				for (index in 0...targets)
					builder.int(rename(body.auxInt(row, 2 + index)));
				builder.row(IrOpcode.Switch, -1, start, where);
			default:
				builder.copyRow(body, row);
		}
	}

	static function hasPhis(body:IrBody, block:Int):Bool {
		for (row in body.firstRow(block)...body.instructionEnd(block))
			if (body.opcode(row) == IrOpcode.Phi)
				return true;
		return false;
	}

	/** Whether block `block` (an index, or -1) already transfers to `target`. */
	static function reaches(body:IrBody, block:Int, target:Int):Bool {
		if (block < 0)
			return false;
		var terminator = body.terminatorRow(block);
		if (terminator < 0)
			return false;
		return switch body.opcode(terminator) {
			case IrOpcode.Jump, IrOpcode.Branch, IrOpcode.Switch:
				var found = false;
				for (index in 0...body.successorCount(terminator))
					if (body.successor(terminator, index) == target)
						found = true;
				found;
			default: false;
		};
	}

	static function finalTarget(id:Int, bridges:Map<Int, BodyJumpBridge>):Int {
		while (bridges.exists(id))
			id = bridges.get(id).target;
		return id;
	}

	static function originalPredecessor(id:Int, bridges:Map<Int, BodyJumpBridge>):Int {
		while (bridges.exists(id))
			id = bridges.get(id).predecessor;
		return id;
	}

	/** `IrJumpThreading.threadConstantBranches` on a body. */
	public static function threadConstantBranches(body:IrBody, scratch:IrPassScratch):IrBody {
		var count = body.blockCount(), shaped = false;
		for (block in 1...count) {
			var terminator = body.terminatorRow(block), first = body.firstRow(block);
			if (terminator == first + 1 && body.opcode(first) == IrOpcode.Phi
				&& body.opcode(terminator) == IrOpcode.Branch
				&& body.operand(terminator, 0) == body.output(first)) {
				shaped = true;
				break;
			}
		}
		if (!shaped)
			return body;
		// By value id: the constant a ConstBool gives (0 or 1, else -1), and how many times the value is used.
		var constants = IrPassScratch.filledInts(scratch.firstInts, body.valueLimit(), -1),
			uses = IrPassScratch.filledInts(scratch.secondInts, body.valueLimit(), 0);
		for (block in 0...count) {
			for (row in body.firstRow(block)...body.instructionEnd(block)) {
				switch body.opcode(row) {
					case IrOpcode.ConstBool:
						constants[body.output(row)] = body.aux(row);
					case IrOpcode.BeginTry, IrOpcode.EndTry, IrOpcode.Catch:
						return body;
					default:
				}
				for (index in 0...body.operandCount(row))
					uses[body.operand(row, index)]++;
			}
			var terminator = body.terminatorRow(block);
			if (terminator >= 0)
				for (index in 0...body.operandCount(terminator))
					uses[body.operand(terminator, index)]++;
		}
		for (index in 0...body.bindingCount())
			uses[body.bindingValue(index)]++;
		var size = 0;
		for (block in 0...count)
			if (body.blockId(block) >= size)
				size = body.blockId(block) + 1;
		var indices = scratch.bodyGraph.reset(body),
			redirects:Map<Int, Int> = [],
			skipped:Map<Int, Array<Int>> = [],
			added:Map<Int, Array<Int>> = [],
			threaded:Map<Int, Bool> = [];
		inline function indexOrNone(id:Int):Int
			return indices.contains(id) ? indices.indexOf(id) : -1;
		for (block in 1...count) {
			var id = body.blockId(block), first = body.firstRow(block), terminator = body.terminatorRow(block);
			if (terminator != first + 1 || body.opcode(first) != IrOpcode.Phi
				|| body.opcode(terminator) != IrOpcode.Branch)
				continue;
			var phi = body.output(first), yes = body.auxInt(terminator, 0), no = body.auxInt(terminator, 1);
			if (body.operand(terminator, 0) != phi || uses[phi] != 1 || yes == id || no == id || !indices.contains(yes)
				|| !indices.contains(no))
				continue;
			for (input in 0...body.operandCount(first)) {
				var from = body.auxInt(first, input),
					value = body.operand(first, input),
					target = constants[value] >= 0 ? (constants[value] == 1 ? yes : no) : -1,
					targetBlock = target >= 0 ? indexOrNone(target) : -1;
				if (targetBlock < 0)
					continue;
				var key = from * size + target;
				if (from == id || from == target
					|| hasPhis(body, targetBlock) && (reaches(body, indexOrNone(from), target) || threaded.exists(key)))
					continue;
				threaded.set(key, true);
				redirects.set(from * size + id, target);
				if (!skipped.exists(id))
					skipped.set(id, []);
				skipped.get(id).push(from);
				for (row in body.firstRow(targetBlock)...body.instructionEnd(targetBlock))
					if (body.opcode(row) == IrOpcode.Phi)
						for (targetInput in 0...body.operandCount(row))
							if (body.auxInt(row, targetInput) == id) {
								var targetPhi = body.output(row), targetValue = body.operand(row, targetInput);
								if (!added.exists(targetPhi))
									added.set(targetPhi, []);
								var list = added.get(targetPhi);
								list.push(from);
								list.push(targetValue == phi ? value : targetValue);
							}
			}
		}
		if (!skipped.keys().hasNext())
			return body;
		var builder = scratch.bodyBuilder;
		builder.startFrom(body);
		for (block in 0...count) {
			var id = body.blockId(block), skippedBy = skipped.get(id);
			if (skippedBy == null) {
				builder.beginBlock(id);
				for (row in body.firstRow(block)...body.instructionEnd(block)) {
					var extra = body.opcode(row) == IrOpcode.Phi ? added.get(body.output(row)) : null;
					if (extra == null) {
						builder.copyRow(body, row);
						continue;
					}
					var start = builder.poolStart();
					for (index in 0...body.operandCount(row)) {
						builder.operandId(body.operand(row, index));
						builder.int(body.auxInt(row, index));
					}
					var pair = 0;
					while (pair < extra.length) {
						builder.operandId(extra[pair + 1]);
						builder.int(extra[pair]);
						pair += 2;
					}
					builder.row(IrOpcode.Phi, body.output(row), start, body.provenance(row));
				}
			} else {
				var first = body.firstRow(block), kept = 0;
				for (index in 0...body.operandCount(first))
					if (skippedBy.indexOf(body.auxInt(first, index)) < 0)
						kept++;
				// Every predecessor jumps past it: nothing reaches the block.
				if (kept == 0)
					continue;
				builder.beginBlock(id);
				var start = builder.poolStart();
				for (index in 0...body.operandCount(first))
					if (skippedBy.indexOf(body.auxInt(first, index)) < 0) {
						builder.operandId(body.operand(first, index));
						builder.int(body.auxInt(first, index));
					}
				builder.row(IrOpcode.Phi, body.output(first), start, body.provenance(first));
			}
			var terminator = body.terminatorRow(block);
			if (terminator >= 0)
				retargetTerminator(body, terminator, builder, target -> {
					var redirect = redirects.get(id * size + target);
					redirect != null ? redirect : target;
				});
		}
		for (index in 0...body.bindingCount())
			builder.copyBinding(body, index, body.bindingValue(index));
		return IrBodyUnreachableBlocks.remove(builder.finishFrom(body), scratch);
	}
}
