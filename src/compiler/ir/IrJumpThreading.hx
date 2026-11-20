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
			var copy = new IrBlock(block.id);
			for (located in block.instructions) switch located.value {
				case Phi(out, inputs):
					var rewritten:Array<IrPhiInput> = [for (input in inputs)
						{
							block:originalPredecessor(input.block, bridges), value:input.value
						}];
					copy.instructions.push(new Located(Phi(out, rewritten), located.provenance));
				default: copy.instructions.push(located);
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
	public static function threadConstantBranches(fn:IrFunction):IrFunction {
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
		var constants:Map<Int, Bool> = [], uses:Map<Int, Int> = [];
		function use(value:IrValue):Void
			uses.set(value.id, (uses.exists(value.id) ? uses.get(value.id) : 0) + 1);
		for (block in fn.blocks) {
			for (located in block.instructions) {
				switch located.value {
					case ConstBool(output, value):
						constants.set(output.id, value);
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
			redirects:Map<String, Int> = [],
			skipped:Map<Int, Array<Int>> = [],
			added:Map<Int, Array<IrPhiInput>> = [],
			threaded:Map<String, Bool> = [];
		for (block in fn.blocks) {
			if (block == fn.blocks[0] || block.instructions.length != 1 || block.terminator == null)
				continue;
			switch [block.instructions[0].value, block.terminator.value] {
				case [Phi(phi, inputs),
					Branch(condition, yes, no)] if (condition.id == phi.id && uses.get(phi.id) == 1 && yes != block.id
					&& no != block.id && byId.exists(yes) && byId.exists(no)):
					for (input in inputs) {
						var target = constants.exists(input.value.id) ? (constants.get(input.value.id) ? yes : no) : -1;
						// A target with phis gets an input for the new edge, so a predecessor that already reaches it (it would then
						// have two edges in) is not threaded there.
						var key = input.block + ">" + target, targetBlock = byId.get(target);
						if (targetBlock == null || input.block == block.id || input.block == target
							|| hasPhis(targetBlock) && (reaches(byId.get(input.block), target) || threaded.exists(key)))
							continue;
						threaded.set(key, true);
						redirects.set(input.block + ":" + block.id, target);
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
			var key = from + ":" + to;
			return redirects.exists(key) ? redirects.get(key) : to;
		}
		var blocks:Array<IrBlock> = [];
		for (block in fn.blocks) {
			var skippedBy = skipped.get(block.id), copy = new IrBlock(block.id);
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

	static function originalPredecessor(id:Int, bridges:Map<Int, JumpBridge>):Int {
		while (bridges.exists(id)) id = bridges.get(id).predecessor;
		return id;
	}
}
