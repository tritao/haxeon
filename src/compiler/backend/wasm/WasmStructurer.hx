package compiler.backend.wasm;

import compiler.ir.IrFunction;

/**
 * The facts needed to emit a reducible CFG as structured Wasm control flow, after Ramsey, "Beyond Relooper" (ICFP
 * 2022). Every loop header becomes a `loop`, every node reached by two or more forward edges becomes the end of a
 * `block` that its immediate dominator opens, and a branch to either is a `br` to that frame. Any other target has a
 * single forward predecessor and is emitted inline at the branch.
 *
 * Reducibility is the only requirement: any shape of nested loops, early exits, `break` and `continue` structures.
 */
class WasmStructurer {
	public final functionName:String;
	public final analysis:WasmCfgAnalysis;

	final loopHeaders:Map<Int, Bool> = [];
	final mergeNodes:Map<Int, Bool> = [];
	final mergeChildren:Map<Int, Array<Int>> = [];

	public function new(fn:IrFunction) {
		functionName = fn.name;
		analysis = new WasmCfgAnalysis(fn);
		if (analysis.reducible)
			plan();
	}

	/** True when the CFG can be emitted with structured regions. */
	public function canUseStructured():Bool
		return analysis.reducible;

	/** Whether `to` dominates `from`, which for a reducible CFG is exactly when the edge returns to a loop header. */
	public function isBackEdge(from:Int, to:Int):Bool
		return analysis.graph.dominates(to, from);

	public function isLoopHeader(id:Int):Bool
		return loopHeaders.exists(id);

	/** Whether two or more forward edges enter the block, so its code is laid out after a `block` rather than inline. */
	public function isMergeNode(id:Int):Bool
		return mergeNodes.exists(id);

	/** The merge nodes the block immediately dominates, in reverse postorder (the order their code is laid out). */
	public function mergeChildrenOf(id:Int):Array<Int> {
		var children = mergeChildren.get(id);
		return children == null ? [] : children;
	}

	function plan():Void {
		var graph = analysis.graph, forwardEdges:Map<Int, Int> = [];
		for (to in graph.order) {
			var predecessors = graph.predecessors.get(to);
			if (predecessors == null)
				continue;
			for (from in predecessors)
				if (isBackEdge(from, to))
					loopHeaders.set(to, true);
				else
					forwardEdges.set(to, (forwardEdges.exists(to) ? forwardEdges.get(to) : 0) + 1);
		}
		// Reverse postorder, so each list below is already in layout order.
		for (id in graph.order)
			if (forwardEdges.exists(id) && forwardEdges.get(id) >= 2) {
				mergeNodes.set(id, true);
				var parent = graph.immediate.get(id);
				if (parent == null || parent == id)
					continue;
				var siblings = mergeChildren.get(parent);
				if (siblings == null) {
					siblings = [];
					mergeChildren.set(parent, siblings);
				}
				siblings.push(id);
			}
	}
}
