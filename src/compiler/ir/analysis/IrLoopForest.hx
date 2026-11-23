package compiler.ir.analysis;

import compiler.ir.cfg.IrBodyGraph;
import compiler.ir.model.IrBody;

/**
 * The natural loops of a body, nested: a loop is a header block and the blocks that reach a back edge into it (an edge from a
 * block the header dominates) without passing the header. Loops by index, outer ones before the ones they hold; blocks by id.
 * An irreducible cycle has no back edge in this sense and is no loop here.
 */
class IrLoopForest {
	/** By loop, its header block id, its parent loop (-1 for an outermost one) and its depth (1 for an outermost one). */
	final headers:Array<Int> = [];

	final parents:Array<Int> = [];
	final depths:Array<Int> = [];

	/** By block id, the innermost loop that holds it, or -1. */
	final innermost:Array<Int> = [];

	public function new(body:IrBody, graph:IrBodyGraph) {
		var size = 0;
		for (block in 0...body.blockCount())
			if (body.blockId(block) >= size)
				size = body.blockId(block) + 1;
		for (_ in 0...size)
			innermost.push(-1);
		// Headers in reverse postorder are outer before inner: a loop's header dominates the headers of the loops inside it.
		var claimed = [for (_ in 0...size) -1];
		for (header in graph.order) {
			var blocks:Null<Array<Int>> = null, loop = headers.length;
			for (index in 0...graph.predecessorCount(header)) {
				var tail = graph.predecessor(header, index);
				if (!graph.dominates(header, tail))
					continue;
				if (blocks == null) {
					blocks = [header];
					claimed[header] = loop;
				}
				var pending = [tail];
				while (pending.length > 0) {
					var id = pending.pop();
					if (claimed[id] == loop)
						continue;
					claimed[id] = loop;
					blocks.push(id);
					for (edge in 0...graph.predecessorCount(id))
						if (graph.isReachable(graph.predecessor(id, edge)))
							pending.push(graph.predecessor(id, edge));
				}
			}
			if (blocks == null)
				continue;
			headers.push(header);
			// The loops around this one came first, so the innermost loop holding its header so far is its parent; its blocks
			// are now its own innermost loop's until a loop inside it claims them.
			var parent = innermost[header];
			parents.push(parent);
			depths.push(parent < 0 ? 1 : depths[parent] + 1);
			for (id in blocks)
				innermost[id] = loop;
		}
	}

	public inline function count():Int
		return headers.length;

	public inline function header(loop:Int):Int
		return headers[loop];

	/** The loop around `loop`, or -1. */
	public inline function parent(loop:Int):Int
		return parents[loop];

	public inline function depth(loop:Int):Int
		return depths[loop];

	/** The innermost loop holding block `id`, or -1. */
	public inline function loopOf(id:Int):Int
		return id >= 0 && id < innermost.length ? innermost[id] : -1;

	/** How many loops hold block `id`. */
	public function depthOf(id:Int):Int {
		var loop = loopOf(id);
		return loop < 0 ? 0 : depths[loop];
	}

	/** Whether `loop` holds block `id`, directly or through a loop inside it. */
	public function contains(loop:Int, id:Int):Bool {
		var current = loopOf(id);
		while (current >= 0 && current > loop)
			current = parents[current];
		return current == loop;
	}
}
