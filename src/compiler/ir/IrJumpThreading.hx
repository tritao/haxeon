package compiler.ir;

import compiler.ir.Ir;
import compiler.ir.SourceProvenance.Located;

private typedef JumpBridge = {final predecessor:Int; final target:Int;}

/** Thread linear edges through empty jump blocks while preserving SSA phi edges. */
class IrJumpThreading {
	public static function run(fn:IrFunction):IrFunction {
		if (fn.blocks.length < 3) return fn;
		var candidate = false;
		for (block in fn.blocks) {
			if (block != fn.blocks[0] && block.instructions.length == 0 && block.terminator != null)
				switch block.terminator.value { case Jump(_): candidate = true; default: }
			for (located in block.instructions) switch located.value {
				// Handler and cleanup destinations have instruction-level semantics not represented by normal edges alone.
				case BeginTry(_, _, _), EndTry(_, _), Catch(_): return fn;
				default:
			}
		}
		if (!candidate) return fn;
		var graph = new IrGraph(fn), external:Map<Int, Bool> = [], bridges:Map<Int, JumpBridge> = [];
		// Reachability analysis ignores dead blocks. Preserve any IDs that a dead edge or phi still mentions.
		for (block in fn.blocks) if (!graph.immediate.exists(block.id)) {
			if (block.terminator != null) switch block.terminator.value {
				case Jump(target): external.set(target, true);
				case Branch(_, yes, no): external.set(yes, true); external.set(no, true);
				default:
			}
			for (located in block.instructions) switch located.value {
				case Phi(_, inputs): for (input in inputs) external.set(input.block, true);
				default:
			}
		}
		for (bridge in fn.blocks) {
			if (bridge.id == fn.blocks[0].id || bridge.instructions.length != 0 || bridge.terminator == null
				|| !graph.immediate.exists(bridge.id) || external.exists(bridge.id)) continue;
			var target = switch bridge.terminator.value { case Jump(id): id; default: -1; };
			if (target < 0 || target == bridge.id || !graph.blocks.exists(target)) continue;
			var predecessors = graph.predecessors.get(bridge.id);
			if (predecessors == null || predecessors.length != 1 || predecessors[0] == bridge.id || predecessors[0] == target) continue;
			var term = graph.block(predecessors[0]).terminator;
			if (term == null) continue;
			switch term.value {
				case Jump(_): bridges.set(bridge.id, {predecessor: predecessors[0], target: target});
				default:
			}
		}
		if (!bridges.keys().hasNext()) return fn;
		var blocks:Array<IrBlock> = [];
		for (block in fn.blocks) if (!bridges.exists(block.id)) {
			var copy = new IrBlock(block.id);
			for (located in block.instructions) switch located.value {
				case Phi(out, inputs):
					var rewritten:Array<IrPhiInput> = [for (input in inputs)
						{block: originalPredecessor(input.block, bridges), value: input.value}];
					copy.instructions.push(new Located(Phi(out, rewritten), located.provenance));
				default: copy.instructions.push(located);
			}
			var term = block.terminator;
			if (term != null) switch term.value {
				case Jump(target): copy.terminator = new Located(Jump(finalTarget(target, bridges)), term.provenance);
				default: copy.terminator = term;
			}
			blocks.push(copy);
		}
		return new IrFunction(fn.name, fn.arguments, fn.result, blocks, fn.debugBindings, fn.inlineHint, fn.retention);
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
