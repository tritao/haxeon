package compiler.ir;

import compiler.ir.Ir;
import compiler.ir.SourceProvenance.Located;

private typedef JumpBridge = {
	final predecessor:Int;
	final target:Int;

	/** The predecessor ends in a branch or switch, so the edge it gets may not reach a phi (it would give the phi a second input). */
	final conditional:Bool;
}

/** Thread linear edges through empty jump blocks while preserving SSA phi edges. */
class IrJumpThreading {
	/** `scratch`, when given, lends the graph. */
	public static function run(fn:IrFunction, ?scratch:IrPassScratch):IrFunction {
		if (fn.blocks.length < 3) return fn;
		var candidate = false;
		for (block in fn.blocks) {
			if (block != fn.blocks[0] && block.instructions.length == 0 && block.terminator != null)
				switch block.terminator.value {
					case Jump(_): candidate = true;
					default:
				}
			for (located in block.instructions) switch located.value {
				// Handler and cleanup destinations have instruction-level semantics not represented by normal edges alone.
				case BeginTry(_, _, _), EndTry(_, _), Catch(_): return fn;
				default:
			}
		}
		if (!candidate) return fn;
		var graph = scratch == null ? new IrGraph(fn) : scratch.graph.reset(fn),
			result = threadBridges(fn, graph);
		graph.release();
		return result;
	}

	static function threadBridges(fn:IrFunction, graph:IrGraph):IrFunction {
		var external:Map<Int, Bool> = [], bridges:Map<Int, JumpBridge> = [];
		// Reachability analysis ignores dead blocks. Preserve any IDs that a dead edge or phi still mentions.
		for (block in fn.blocks) if (!graph.isReachable(block.id)) {
			if (block.terminator != null) switch block.terminator.value {
				case Jump(target): external.set(target, true);
				case Branch(_, yes, no): external.set(yes, true);
					external.set(no, true);
				case Switch(_, targets, otherwise):
					for (target in IrSwitch.successors(targets, otherwise))
						external.set(target, true);
				default:
			}
			for (located in block.instructions) switch located.value {
				case Phi(_, inputs): for (input in inputs) external.set(input.block, true);
				default:
			}
		}
		for (bridge in fn.blocks) {
			// Read once: a call would end what a test of `bridge.terminator` proved.
			var bridgeTerminator = bridge.terminator, reachable = graph.isReachable(bridge.id);
			if (bridge.id == fn.blocks[0].id || bridge.instructions.length != 0 || bridgeTerminator == null
				|| !reachable || external.exists(bridge.id)) continue;
			var target = switch bridgeTerminator.value {
				case Jump(id): id;
				default: -1;
			};
			if (target < 0 || target == bridge.id || !graph.contains(target)) continue;
			if (graph.predecessorCount(bridge.id) != 1) continue;
			var only = graph.predecessor(bridge.id, 0);
			if (only == bridge.id || only == target) continue;
			var term = graph.block(only).terminator;
			if (term == null) continue;
			// A conditional predecessor jumps to the target itself when the target has no phis to give a new input to.
			switch term.value {
				case Jump(_): bridges.set(bridge.id,
					{predecessor: only, target: target, conditional: false});
				case Branch(_, _, _), Switch(_, _, _): bridges.set(bridge.id, {
					predecessor: only,
					target: target,
					conditional: true
				});
				default:
			}
		}
		// A conditional predecessor is bridged only when the block its chain of bridges ends at has no phis: two of its edges
		// could end there, and a phi has one input per predecessor.
		for (id in [for (id in bridges.keys()) id])
			if (bridges.get(id).conditional && hasPhis(graph.block(finalTarget(id, bridges))))
				bridges.remove(id);
		if (!bridges.keys().hasNext()) return fn;
		var blocks:Array<IrBlock> = [];
		for (block in fn.blocks) if (!bridges.exists(block.id)) {
			// A block whose phis name no bridge and whose edges reach no bridge is shared as it is.
			if (!namesBridge(block, bridges)) {
				blocks.push(block);
				continue;
			}
			var copy = new IrBlock(block.id, block.instructions.copy());
			for (index in 0...copy.instructions.length) {
				var located = copy.instructions[index];
				switch located.value {
					case Phi(out, inputs):
						var rewritten:Array<IrPhiInput> = [for (input in inputs)
							{
								block:originalPredecessor(input.block, bridges), value:input.value
							}];
						copy.instructions[index] = new Located(Phi(out, rewritten), located.provenance);
					default:
				}
			}
			var term = block.terminator;
			if (term != null) switch term.value {
				case Jump(target): copy.terminator = new Located(Jump(finalTarget(target, bridges)), term.provenance);
				case Branch(condition, yes, no):
					copy.terminator = new Located(Branch(condition, finalTarget(yes, bridges),
						finalTarget(no, bridges)),
						term.provenance);
				case Switch(value, targets, otherwise):
					copy.terminator = new Located(Switch(value,
						IrSwitch.mapTargets(targets, target -> finalTarget(target, bridges)),
						finalTarget(otherwise, bridges)), term.provenance);
				default: copy.terminator = term;
			}
			blocks.push(copy);
		}
		return fn.withBlocks(blocks);
	}

	/** Whether `block` already transfers to `target`. */
	static function reaches(block:Null<IrBlock>, target:Int):Bool {
		if (block == null || block.terminator == null)
			return false;
		return switch block.terminator.value {
			case Jump(to): to == target;
			case Branch(_, yes, no): yes == target || no == target;
			case Switch(_, targets, otherwise): otherwise == target || targets.indexOf(target) >= 0;
			default: false;
		};
	}

	static function hasPhis(block:IrBlock):Bool {
		for (located in block.instructions)
			switch located.value {
				case Phi(_, _): return true;
				default:
			}
		return false;
	}

	/**
	 * `a || b` and `a && b` become a Bool through a phi, and an `if` then branches on it: a block whose only instruction is a phi of
	 * Bools, used only by the block's own branch. A predecessor that feeds it a constant jumps straight to the side that constant
	 * selects, so the Bool is never made on that path; a block every predecessor skips is dropped. Only targets without phis are
	 * threaded to, so no phi gains an input.
	 */
	public static function threadConstantBranches(fn:IrFunction, ?scratch:IrPassScratch):IrFunction {
		// Most functions have no block of that shape: find that out before counting every use.
		var shaped = false;
		for (block in fn.blocks)
			if (block != fn.blocks[0] && block.instructions.length == 1 && block.terminator != null)
				switch [block.instructions[0].value, block.terminator.value] {
					case [Phi(phi, _), Branch(condition, _, _)] if (condition.id == phi.id):
						shaped = true;
						break;
					default:
				}
		if (!shaped)
			return fn;
		// By value id: how many operands read it, and whether it is a Bool constant (`constants`) and which (`constantValues`).
		var tables = scratch ?? new IrPassScratch(),
			uses = tables.firstInts,
			constantValues = tables.secondInts,
			constants = tables.marked;
		uses.resize(0);
		constants.clear();
		function use(value:IrValue):Void {
			while (uses.length <= value.id)
				uses.push(0);
			uses[value.id]++;
		}
		for (block in fn.blocks) {
			for (located in block.instructions) {
				switch located.value {
					case ConstBool(output, value):
						constants.add(output.id);
						while (constantValues.length <= output.id)
							constantValues.push(0);
						constantValues[output.id] = value ? 1 : 0;
					case Phi(_, inputs):
						for (input in inputs)
							use(input.value);
					case BeginTry(_, _, _), EndTry(_, _), Catch(_):
						return fn;
					default:
				}
				for (index in 0...IrOperands.count(located.value))
					use(IrOperands.at(located.value, index));
			}
			if (block.terminator != null)
				switch block.terminator.value {
					case Return(value), Throw(value), Rethrow(value), Branch(value, _, _), Switch(value, _, _):
						use(value);
					case Jump(_), Unreachable:
				}
		}
		for (binding in fn.debugBindings)
			use(binding.value);
		var byId:Map<Int, IrBlock> = [for (block in fn.blocks) block.id => block],
			redirects:Map<Int, Map<Int, Int>> = [],
			skipped:Map<Int, Array<Int>> = [],
			added:Map<Int, Array<IrPhiInput>> = [],
			threaded:Map<String, Bool> = [];
		for (block in fn.blocks) {
			if (block == fn.blocks[0] || block.instructions.length != 1 || block.terminator == null)
				continue;
			switch [block.instructions[0].value, block.terminator.value] {
				case [Phi(phi, inputs),
					Branch(condition, yes, no)] if (condition.id == phi.id && uses[phi.id] == 1 && yes != block.id
					&& no != block.id && byId.exists(yes) && byId.exists(no)):
					for (input in inputs) {
						var target = constants.has(input.value.id)
							? (constantValues[input.value.id] != 0 ? yes : no) : -1;
						// A target with phis gets an input for the new edge, so a predecessor that already reaches it (it would then
						// have two edges in) is not threaded there.
						var key = input.block + ">" + target, targetBlock = byId.get(target);
						if (targetBlock == null || input.block == block.id || input.block == target
							|| hasPhis(targetBlock) && (reaches(byId.get(input.block), target) || threaded.exists(key)))
							continue;
						threaded.set(key, true);
						var from = redirects.get(input.block);
						if (from == null) {
							from = [];
							redirects.set(input.block, from);
						}
						from.set(block.id, target);
						if (!skipped.exists(block.id))
							skipped.set(block.id, []);
						skipped.get(block.id).push(input.block);
						// What each of the target's phis took from this block, it now takes from the predecessor: the predecessor's
						// constant for the block's own phi, or a value from a block that dominates this one, and so the predecessor.
						for (located in targetBlock.instructions)
							switch located.value {
								case Phi(targetPhi, targetInputs):
									for (targetInput in targetInputs)
										if (targetInput.block == block.id) {
											if (!added.exists(targetPhi.id))
												added.set(targetPhi.id, []);
											added.get(targetPhi.id).push({
												block: input.block,
												value: targetInput.value.id == phi.id ? input.value : targetInput.value
											});
										}
								default:
							}
					}
				default:
			}

		}
		if (!skipped.keys().hasNext())
			return fn;
		function retarget(from:Int, to:Int):Int {
			var targets = redirects.get(from);
			return targets != null && targets.exists(to) ? targets.get(to) : to;
		}
		var blocks:Array<IrBlock> = [];
		for (block in fn.blocks) {
			var skippedBy = skipped.get(block.id);
			// A block that is not skipped, gains no phi input and is not redirected is shared as it is.
			if (skippedBy == null && !redirects.exists(block.id) && !gainsInputs(block, added)) {
				blocks.push(block);
				continue;
			}
			var copy = new IrBlock(block.id);
			if (skippedBy == null)
				for (located in block.instructions)
					switch located.value {
						case Phi(output, inputs) if (added.exists(output.id)):
							copy.instructions.push(new Located(Phi(output, inputs.concat(added.get(output.id))),
								located.provenance));
						default:
							copy.instructions.push(located);
					}
						else {
						var phi = block.instructions[0];
						switch phi.value {
							case Phi(output, inputs):
								var kept = [for (input in inputs) if (skippedBy.indexOf(input.block) < 0) input];
								// Every predecessor jumps past it: nothing reaches the block.
								if (kept.length == 0)
									continue;
								copy.instructions.push(new Located(Phi(output, kept), phi.provenance));
							default:
						}
					}
			var term = block.terminator;
			if (term != null)
				copy.terminator = switch term.value {
					case Jump(target): new Located(Jump(retarget(block.id, target)), term.provenance);
					case Branch(condition, yes, no):
						new Located(Branch(condition, retarget(block.id, yes), retarget(block.id, no)),
							term.provenance);
					case Switch(value, targets, otherwise):
						new Located(Switch(value, IrSwitch.mapTargets(targets, target -> retarget(block.id, target)),
							retarget(block.id, otherwise)), term.provenance);
					default: term;
				};
			blocks.push(copy);
		}
		return IrUnreachableBlocks.remove(fn.withBlocks(blocks));
	}

	static function finalTarget(id:Int, bridges:Map<Int, JumpBridge>):Int {
		while (bridges.exists(id)) id = bridges.get(id).target;
		return id;
	}

	static function gainsInputs(block:IrBlock, added:Map<Int, Array<IrPhiInput>>):Bool {
		for (located in block.instructions)
			switch located.value {
				case Phi(output, _) if (added.exists(output.id)):
					return true;
				default:
			}
		return false;
	}

	/** Whether threading `bridges` changes `block`: a phi input from a bridge, or an edge into one. */
	static function namesBridge(block:IrBlock, bridges:Map<Int, JumpBridge>):Bool {
		for (located in block.instructions)
			switch located.value {
				case Phi(_, inputs):
					for (input in inputs)
						if (bridges.exists(input.block))
							return true;
				default:
			}
		var term = block.terminator;
		if (term == null)
			return false;
		return switch term.value {
			case Jump(target): bridges.exists(target);
			case Branch(_, yes, no): bridges.exists(yes) || bridges.exists(no);
			case Switch(_, targets, otherwise):
				if (bridges.exists(otherwise)) true else {
					var found = false;
					for (target in targets)
						if (bridges.exists(target)) {
							found = true;
							break;
						}
					found;
				}
			default: false;
		};
	}

	static function originalPredecessor(id:Int, bridges:Map<Int, JumpBridge>):Int {
		while (bridges.exists(id)) id = bridges.get(id).predecessor;
		return id;
	}

	// The same passes on a body, in place (docs/design/IR_CORE_COLUMNS.md); each says whether it changed the body.

	/** Whether the block (an index) holds a try region's instruction: its rows have semantics normal edges do not show. */
	static function hasTryRows(body:IrBody, block:Int):Bool {
		var row = body.firstRow(block);
		while (row >= 0) {
			switch body.opcode(row) {
				case IrOpcode.BeginTry, IrOpcode.EndTry, IrOpcode.Catch: return true;
				default:
			}
			row = body.nextRow(row);
		}
		return false;
	}

	/** Whether the block (an index) is only a terminator. */
	static inline function onlyTerminator(body:IrBody, block:Int):Bool {
		var terminator = body.terminatorRow(block);
		return terminator >= 0 && body.firstRow(block) == terminator;
	}

	static function blockLimit(body:IrBody):Int {
		var size = 0;
		for (block in 0...body.blockCount())
			if (body.blockId(block) >= size)
				size = body.blockId(block) + 1;
		return size;
	}

	/** `run` on a body. */
	public static function runBody(body:IrBody, scratch:IrPassScratch):Bool {
		var count = body.blockCount();
		if (count < 3)
			return false;
		var candidate = false;
		for (block in 0...count) {
			if (block != 0 && onlyTerminator(body, block) && body.opcode(body.terminatorRow(block)) == IrOpcode.Jump)
				candidate = true;
			if (hasTryRows(body, block))
				return false;
		}
		if (!candidate)
			return false;
		var graph = scratch.bodyGraph.reset(body), size = blockLimit(body), external = scratch.marked;
		// By block id: the predecessor a bridge takes its edge from (-1 when the block is no bridge), and where it jumps, doubled,
		// plus one when the predecessor branches.
		var predecessors = IrPassScratch.filledInts(scratch.firstInts, size, -1),
			targets = IrPassScratch.filledInts(scratch.secondInts, size, 0);
		external.clear();
		for (block in 0...count)
			if (!graph.isReachable(body.blockId(block))) {
				var terminator = body.terminatorRow(block);
				if (terminator >= 0)
					for (index in 0...body.successorCount(terminator))
						external.add(body.successor(terminator, index));
				var row = body.firstRow(block);
				while (row >= 0) {
					if (body.opcode(row) == IrOpcode.Phi)
						for (index in 0...body.operandCount(row))
							external.add(body.auxInt(row, index));
					row = body.nextRow(row);
				}
			}
		var entry = body.blockId(0), bridged = false;
		for (block in 0...count) {
			var id = body.blockId(block);
			if (id == entry || !onlyTerminator(body, block) || !graph.isReachable(id) || external.has(id))
				continue;
			var terminator = body.terminatorRow(block);
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
				case IrOpcode.Jump:
					predecessors[id] = only;
					targets[id] = target * 2;
					bridged = true;
				case IrOpcode.Branch, IrOpcode.Switch:
					predecessors[id] = only;
					targets[id] = target * 2 + 1;
					bridged = true;
				default:
			}
		}
		if (!bridged)
			return false;
		inline function isBridge(id:Int):Bool
			return id >= 0 && id < size && predecessors[id] >= 0;
		function finalTarget(id:Int):Int {
			while (isBridge(id))
				id = targets[id] >> 1;
			return id;
		}
		// Only the first bridge of a chain can follow a branch (the next one's predecessor is a bridge, which jumps), so the order
		// these are dropped in does not matter.
		bridged = false;
		for (id in 0...size)
			if (isBridge(id)) {
				if (targets[id] & 1 == 1 && blockHasPhis(body, graph.indexOf(finalTarget(id))))
					predecessors[id] = -1;
				else
					bridged = true;
			}
		if (!bridged)
			return false;
		var block = count - 1;
		while (block >= 0) {
			var id = body.blockId(block);
			if (isBridge(id)) {
				body.removeBlock(block);
				block--;
				continue;
			}
			var row = body.firstRow(block);
			while (row >= 0) {
				if (body.opcode(row) == IrOpcode.Phi)
					for (index in 0...body.operandCount(row)) {
						var from = body.auxInt(row, index);
						if (isBridge(from)) {
							while (isBridge(from))
								from = predecessors[from];
							body.setAuxInt(row, index, from);
						}
					}
				row = body.nextRow(row);
			}
			var terminator = body.terminatorRow(block);
			if (terminator >= 0)
				for (index in 0...targetCount(body, terminator)) {
					var target = targetAt(body, terminator, index);
					if (isBridge(target))
						setTargetAt(body, terminator, index, finalTarget(target));
				}
			block--;
		}
		return true;
	}

	/** How many target fields a terminator row has: a jump's, a branch's two, a switch's otherwise and targets. */
	static function targetCount(body:IrBody, row:Int):Int
		return switch body.opcode(row) {
			case IrOpcode.Jump: 1;
			case IrOpcode.Branch: 2;
			case IrOpcode.Switch: 1 + body.auxInt(row, 1);
			default: 0;
		};

	/** Target field `index` of a terminator row (a switch's otherwise first, then its targets). */
	static function targetAt(body:IrBody, row:Int, index:Int):Int
		return switch body.opcode(row) {
			case IrOpcode.Jump: body.aux(row);
			case IrOpcode.Switch: body.auxInt(row, index == 0 ? 0 : index + 1);
			default: body.auxInt(row, index);
		};

	static function setTargetAt(body:IrBody, row:Int, index:Int, target:Int):Void
		switch body.opcode(row) {
			case IrOpcode.Jump: body.setAux(row, target);
			case IrOpcode.Switch: body.setAuxInt(row, index == 0 ? 0 : index + 1, target);
			default: body.setAuxInt(row, index, target);
		}

	static function blockHasPhis(body:IrBody, block:Int):Bool {
		var row = body.firstRow(block);
		while (row >= 0) {
			if (body.opcode(row) == IrOpcode.Phi)
				return true;
			row = body.nextRow(row);
		}
		return false;
	}

	/** Whether block `block` (an index, or -1) already transfers to `target`. */
	static function bodyReaches(body:IrBody, block:Int, target:Int):Bool {
		var terminator = block >= 0 ? body.terminatorRow(block) : -1;
		if (terminator < 0)
			return false;
		for (index in 0...body.successorCount(terminator))
			if (body.successor(terminator, index) == target)
				return true;
		return false;
	}

	/** `threadConstantBranches` on a body. */
	public static function threadConstantBranchesBody(body:IrBody, scratch:IrPassScratch):Bool {
		var count = body.blockCount();
		inline function phiBranch(block:Int):Bool {
			var first = body.firstRow(block), terminator = body.terminatorRow(block);
			return terminator >= 0 && first != terminator && body.nextRow(first) == terminator
				&& body.opcode(first) == IrOpcode.Phi && body.opcode(terminator) == IrOpcode.Branch
				&& body.operand(terminator, 0) == body.output(first);
		}
		var shaped = false;
		for (block in 1...count)
			if (phiBranch(block)) {
				shaped = true;
				break;
			}
		if (!shaped)
			return false;
		// By value id: the constant a ConstBool gives (0 or 1, else -1), and how many operands read it.
		var constants = IrPassScratch.filledInts(scratch.firstInts, body.valueLimit(), -1),
			uses = IrPassScratch.filledInts(scratch.secondInts, body.valueLimit(), 0);
		for (block in 0...count) {
			var row = body.firstRow(block);
			while (row >= 0) {
				switch body.opcode(row) {
					case IrOpcode.ConstBool:
						constants[body.output(row)] = body.aux(row);
					case IrOpcode.BeginTry, IrOpcode.EndTry, IrOpcode.Catch:
						return false;
					default:
				}
				for (index in 0...body.operandCount(row))
					uses[body.operand(row, index)]++;
				row = body.nextRow(row);
			}
		}
		for (index in 0...body.bindingCount())
			uses[body.bindingValue(index)]++;
		var size = blockLimit(body), indices = IrPassScratch.filledInts(scratch.thirdInts, size, -1);
		for (block in 0...count)
			indices[body.blockId(block)] = block;
		inline function indexOf(id:Int):Int
			return id >= 0 && id < size ? indices[id] : -1;
		// Threads, as (from, through, to): `from` now goes to `to` where it went to `through`. Inputs, as (phi, from, value): a
		// phi of `to` gains `value` from `from`.
		var threads = scratch.firstTuples, inputs = scratch.secondTuples;
		threads.resize(0);
		inputs.resize(0);
		function threaded(from:Int, to:Int):Bool {
			var index = 0;
			while (index < threads.length) {
				if (threads[index] == from && threads[index + 2] == to)
					return true;
				index += 3;
			}
			return false;
		}
		for (block in 1...count) {
			if (!phiBranch(block))
				continue;
			var id = body.blockId(block), first = body.firstRow(block), terminator = body.terminatorRow(block);
			var phi = body.output(first), yes = body.auxInt(terminator, 0), no = body.auxInt(terminator, 1);
			if (uses[phi] != 1 || yes == id || no == id || indexOf(yes) < 0 || indexOf(no) < 0)
				continue;
			for (input in 0...body.operandCount(first)) {
				var from = body.auxInt(first, input), value = body.operand(first, input);
				var target = constants[value] >= 0 ? (constants[value] == 1 ? yes : no) : -1,
					targetBlock = indexOf(target);
				// A target with phis gets an input for the new edge, so a predecessor that already reaches it (it would then have
				// two edges in) is not threaded there.
				if (targetBlock < 0 || from == id || from == target
					|| blockHasPhis(body, targetBlock) && (bodyReaches(body, indexOf(from), target)
					|| threaded(from, target)))
					continue;
				threads.push(from);
				threads.push(id);
				threads.push(target);
				// What each of the target's phis took from this block, it now takes from the predecessor: the predecessor's
				// constant for the block's own phi, or a value from a block that dominates this one, and so the predecessor.
				var row = body.firstRow(targetBlock);
				while (row >= 0) {
					if (body.opcode(row) == IrOpcode.Phi)
						for (targetInput in 0...body.operandCount(row))
							if (body.auxInt(row, targetInput) == id) {
								var targetValue = body.operand(row, targetInput);
								inputs.push(body.output(row));
								inputs.push(from);
								inputs.push(targetValue == phi ? value : targetValue);
							}
					row = body.nextRow(row);
				}
			}
		}
		if (threads.length == 0)
			return false;
		function skips(through:Int, from:Int):Bool {
			var index = 0;
			while (index < threads.length) {
				if (threads[index + 1] == through && threads[index] == from)
					return true;
				index += 3;
			}
			return false;
		}
		function skipped(through:Int):Bool {
			var index = 1;
			while (index < threads.length) {
				if (threads[index] == through)
					return true;
				index += 3;
			}
			return false;
		}
		// The last thread recorded for an edge is the one it takes.
		function redirect(from:Int, to:Int):Int {
			var index = threads.length - 3;
			while (index >= 0) {
				if (threads[index] == from && threads[index + 1] == to)
					return threads[index + 2];
				index -= 3;
			}
			return to;
		}
		var block = count - 1;
		while (block >= 0) {
			var id = body.blockId(block);
			if (!skipped(id)) {
				var row = body.firstRow(block);
				while (row >= 0) {
					if (body.opcode(row) == IrOpcode.Phi) {
						var output:Int = body.output(row), index = 0;
						while (index < inputs.length) {
							if (inputs[index] == output)
								body.addPhiInput(row, inputs[index + 1], IrValueId.of(inputs[index + 2]));
							index += 3;
						}
					}
					row = body.nextRow(row);
				}
			} else {
				var first = body.firstRow(block), input = body.operandCount(first) - 1;
				while (input >= 0) {
					if (skips(id, body.auxInt(first, input)))
						body.removePhiInput(first, input);
					input--;
				}
				// Every predecessor jumps past it: nothing reaches the block.
				if (body.operandCount(first) == 0) {
					body.removeBlock(block);
					block--;
					continue;
				}
			}
			var terminator = body.terminatorRow(block);
			if (terminator >= 0)
				for (index in 0...targetCount(body, terminator)) {
					var target = targetAt(body, terminator, index), redirected = redirect(id, target);
					if (redirected != target)
						setTargetAt(body, terminator, index, redirected);
				}
			block--;
		}
		IrUnreachableBlocks.removeBody(body, scratch);
		return true;
	}
}
