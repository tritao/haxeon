package compiler.backend.wasm;

import compiler.ir.Ir.IrBlock;
import compiler.ir.IrFunction;
import compiler.ir.IrGraph;

typedef WasmCfgScc = {
	final blocks:Array<Int>;
	final cyclic:Bool;
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
			for (to in graph.successors.get(from))
				if (graph.dominates(to, from))
					result.push({from: from, to: to});
		return result;
	}

	function computePostDominators():Void {
		var exits:Array<Int> = [];
		for (id in graph.order)
			if (graph.successors.get(id).length == 0)
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
				var successors = graph.successors.get(id), next = copySet(all);
				for (successor in successors)
					next = intersectSets(next, sets.get(successor));
				next.set(id, true);
				if (!sameSet(next, sets.get(id))) {
					sets.set(id, next);
					changed = true;
				}
			}
		}
		for (id in graph.order) {
			var candidates:Array<Int> = [];
			for (candidate in sets.get(id).keys())
				if (candidate != id)
					candidates.push(candidate);
			var immediate:Null<Int> = null;
			for (candidate in candidates) {
				var closest = true;
				for (other in candidates)
					if (other != candidate && sets.get(other).exists(candidate)) {
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
		var nextIndex = 0, stack:Array<Int> = [], onStack:Map<Int, Bool> = [], indices:Map<Int, Int> = [], low:Map<Int, Int> = [],
			result:Array<WasmCfgScc> = [];
		function visit(id:Int):Void {
			indices.set(id, nextIndex);
			low.set(id, nextIndex++);
			stack.push(id);
			onStack.set(id, true);
			for (successor in graph.successors.get(id)) {
				if (!indices.exists(successor)) {
					visit(successor);
					low.set(id, Std.int(Math.min(low.get(id), low.get(successor))));
				} else if (onStack.exists(successor))
					low.set(id, Std.int(Math.min(low.get(id), indices.get(successor))));
			}
			if (low.get(id) == indices.get(id)) {
				var members = [], member:Int;
				do {
					member = stack.pop();
					onStack.remove(member);
					members.push(member);
				} while (member != id);
				var cyclic = members.length > 1;
				if (!cyclic)
					for (successor in graph.successors.get(id))
						if (successor == id)
							cyclic = true;
				result.push({blocks: members, cyclic: cyclic});
			}
		}
		for (id in graph.order)
			if (!indices.exists(id))
				visit(id);
		return result;
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
				for (predecessor in graph.predecessors.get(id))
					if (!members.exists(predecessor))
						entries.set(id, true);
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
}
