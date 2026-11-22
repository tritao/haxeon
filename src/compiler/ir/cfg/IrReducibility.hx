package compiler.ir.cfg;

import compiler.core.InternalError;
import compiler.ir.model.IrFunction;

/**
 * Rejects irreducible control flow: a cycle that can be entered other than through its header. The SSA construction
 * (`IrSsaVariables`, after Braun et al.) is minimal only on reducible graphs and has no minimization for the others, and
 * Haxe's structured control flow never makes one, so one here means a lowering went wrong (`DIRECT_SSA.md`).
 *
 * In reverse postorder, an edge whose target is not later than its source is a retreating edge, one that closes a cycle; the
 * graph is reducible exactly when every such edge's target dominates its source, which makes the target the cycle's header.
 */
class IrReducibility {
	public static function verify(fn:IrFunction, graph:IrGraph):Void {
		var order = graph.order, rank:Array<Int> = [];
		for (index in 0...order.length) {
			var id = order[index];
			if (id >= rank.length)
				rank.resize(id + 1);
			rank[id] = index;
		}
		for (index in 0...order.length) {
			var from = order[index];
			for (edge in 0...graph.successorCount(from)) {
				var to = graph.successor(from, edge);
				if (rank[to] <= index && !graph.dominates(to, from))
					throw new InternalError('IR function ${fn.name} has irreducible control flow: '
						+ 'the edge from block $from to block $to closes a cycle that block $to does not head');
			}
		}
	}
}
