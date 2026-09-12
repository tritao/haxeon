package compiler.backend.wasm;

import compiler.ir.Ir.IrBlock;
import compiler.ir.IrFunction;
import compiler.ir.IrGraph;

typedef WasmCfgScc = {
	final blocks:Array<Int>;
	final cyclic:Bool;
}

private typedef WasmSccTraversal = {
	var nextIndex:Int;
	final stack:Array<Int>;
	final onStack:Map<Int, Bool>;
	final indices:Map<Int, Int>;
	final low:Map<Int, Int>;
	final result:Array<WasmCfgScc>;
}

/** CFG facts consumed by structuring and diagnostics; no Wasm representation leaks in. */
class WasmCfgAnalysis {
	public final functionName:String;
	public final graph:IrGraph;
	public final postImmediate:Map<Int, Int> = [];
	public final sccs:Array<WasmCfgScc>;
	public final reducible:Bool;

	public function new(fn:IrFunction) {
		functionName = fn.name;
		graph = new IrGraph(fn);
		computePostDominators();
		sccs = computeSccs();
		reducible = isReducible();
	}

	public function mergeFor(left:Int, right:Int):Null<Int> {
		var leftChain = postDominanceChain(left),
			rightChain = postDominanceChain(right);
		for (candidate in leftChain)
			if (rightChain.indexOf(candidate) >= 0)
				return candidate;
		return null;
	}

	public function backEdges():Array<{from:Int, to:Int}> {
		var result = [];
		for (from in graph.order)
			for (to in requiredSuccessors(graph.successors, from))
				if (graph.dominates(to, from))
					result.push({from: from, to: to});
		return result;
	}

	function computePostDominators():Void {
		var exits:Array<Int> = [];
		for (id in graph.order)
			if (requiredSuccessors(graph.successors, id).length == 0)
				exits.push(id);
		if (exits.length == 0)
			throw 'CFG ${functionName} has no exit block';
		var all:Map<Int, Bool> = [];
		for (id in graph.order)
			all.set(id, true);
		var sets:Map<Int, Map<Int, Bool>> = [];
		for (id in graph.order)
			sets.set(id, exits.indexOf(id) >= 0 ? [id => true] : copySet(all));
		var changed = true;
		while (changed) {
			changed = false;
			for (id in graph.order) {
				if (exits.indexOf(id) >= 0)
					continue;
				var successors = requiredSuccessors(graph.successors, id),
					next = copySet(all);
				for (successor in successors)
					next = intersectSets(next, requiredSet(sets, successor));
				next.set(id, true);
				if (!sameSet(next, requiredSet(sets, id))) {
					sets.set(id, next);
					changed = true;
				}
			}
		}
		for (id in graph.order) {
			var candidates:Array<Int> = [];
			for (candidate in requiredSet(sets, id).keys())
				if (candidate != id)
					candidates.push(candidate);
			var immediate:Null<Int> = null;
			for (candidate in candidates) {
				var closest = true;
				for (other in candidates)
					if (other != candidate && requiredSet(sets, other).exists(candidate)) {
						closest = false;
						break;
					}
				if (closest) {
					immediate = candidate;
					break;
				}
			}
			postImmediate.set(id, immediate == null ? id : immediate);
		}
	}

	function postDominanceChain(id:Int):Array<Int> {
		var result = [], seen:Map<Int, Bool> = [];
		while (!seen.exists(id)) {
			seen.set(id, true);
			result.push(id);
			var next = postImmediate.get(id);
			if (next == null || next == id)
				break;
			id = next;
		}
		return result;
	}

	function computeSccs():Array<WasmCfgScc> {
		var traversal:WasmSccTraversal = {
			nextIndex: 0,
			stack: [],
			onStack: [],
			indices: [],
			low: [],
			result: []
		};
		for (id in graph.order)
			if (!traversal.indices.exists(id))
				visitScc(graph, id, traversal);
		return traversal.result;
	}

	static function visitScc(graph:IrGraph, id:Int, traversal:WasmSccTraversal):Void {
		traversal.indices.set(id, traversal.nextIndex);
		traversal.low.set(id, traversal.nextIndex++);
		traversal.stack.push(id);
		traversal.onStack.set(id, true);
		for (successor in requiredSuccessors(graph.successors, id)) {
			if (!traversal.indices.exists(successor)) {
				visitScc(graph, successor, traversal);
				traversal.low.set(id, Std.int(Math.min(requiredIndex(traversal.low, id), requiredIndex(traversal.low, successor))));
			} else if (traversal.onStack.exists(successor))
				traversal.low.set(id, Std.int(Math.min(requiredIndex(traversal.low, id), requiredIndex(traversal.indices, successor))));
		}
		if (requiredIndex(traversal.low, id) != requiredIndex(traversal.indices, id))
			return;
		var members:Array<Int> = [], member:Int;
		do {
			member = traversal.stack.pop();
			traversal.onStack.remove(member);
			members.push(member);
		} while (member != id);
		var cyclic = members.length > 1;
		if (!cyclic)
			for (successor in requiredSuccessors(graph.successors, id))
				if (successor == id)
					cyclic = true;
		traversal.result.push({blocks: members, cyclic: cyclic});
	}

	function isReducible():Bool {
		for (scc in sccs) {
			if (!scc.cyclic)
				continue;
			var members:Map<Int, Bool> = [];
			for (id in scc.blocks)
				members.set(id, true);
			var entries:Map<Int, Bool> = [];
			for (id in scc.blocks)
				for (predecessor in requiredSuccessors(graph.predecessors, id))
					if (!members.exists(predecessor))
						entries.set(id, true);
			// The function entry has an implicit predecessor outside the CFG. Model
			// it as an entry when it belongs to this SCC, so entry-rooted loops get
			// the same single-header reducibility check as other loops.
			var functionEntry = graph.order[0];
			if (members.exists(functionEntry))
				entries.set(functionEntry, true);
			if (entries.keys().hasNext()) {
				var header:Null<Int> = null;
				for (candidate in entries.keys()) {
					var dominatesAll = true;
					for (member in scc.blocks)
						if (!graph.dominates(candidate, member)) {
							dominatesAll = false;
							break;
						}
					if (dominatesAll) {
						header = candidate;
						break;
					}
				}
				if (header == null)
					return false;
			}
		}
		return true;
	}

	static function copySet(source:Map<Int, Bool>):Map<Int, Bool> {
		var result:Map<Int, Bool> = [];
		for (key in source.keys())
			result.set(key, true);
		return result;
	}

	static function intersectSets(left:Map<Int, Bool>, right:Map<Int, Bool>):Map<Int, Bool> {
		var result:Map<Int, Bool> = [];
		for (key in left.keys())
			if (right.exists(key))
				result.set(key, true);
		return result;
	}

	static function sameSet(left:Map<Int, Bool>, right:Map<Int, Bool>):Bool {
		for (key in left.keys())
			if (!right.exists(key))
				return false;
		for (key in right.keys())
			if (!left.exists(key))
				return false;
		return true;
	}

	static function requiredSuccessors(source:Map<Int, Array<Int>>, block:Int):Array<Int> {
		if (!source.exists(block))
			throw 'CFG is missing adjacency for block $block';
		return source.get(block);
	}

	static function requiredSet(source:Map<Int, Map<Int, Bool>>, block:Int):Map<Int, Bool> {
		if (!source.exists(block))
			throw 'CFG is missing dominance set for block $block';
		return source.get(block);
	}

	static function requiredIndex(source:Map<Int, Int>, block:Int):Int {
		if (!source.exists(block))
			throw 'CFG is missing index for block $block';
		return source.get(block);
	}
}
