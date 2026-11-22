package compiler.ir.analysis;

import compiler.ir.cfg.IrBodyGraph;
import compiler.ir.model.IrBody;
import compiler.ir.model.IrOpcode;
import compiler.ir.model.IrValueId;

/**
 * What the passes over one body share about it, each part made the first time one asks for it: the block and place of every row,
 * the rows that read each value, the control flow graph with its dominators (`IrBodyGraph`), and the loop forest with its
 * induction variables (`IrLoopForest`).
 *
 * It is cached on the body (`of`) and holds while the body has the edit count it was made at: a frozen body keeps its analysis
 * for good, and an edit to one that is not frozen makes the next `of` analyze it again. Whoever keeps bodies past the passes
 * that read them drops their analyses (`release`), so a session holds none.
 */
class IrBodyAnalysis {
	public final body:IrBody;

	/** The body's edit count when this was made. */
	final edits:Int;

	var rowTable:Null<IrRowTable> = null;
	var useTable:Null<IrUseTable> = null;
	var controlFlow:Null<IrBodyGraph> = null;
	var loopForest:Null<IrLoopForest> = null;

	/** A worklist and visit stamps by block id, for the rare dominance question across a try region (`dominatesRow`). */
	var visited:Null<Array<Int>> = null;

	var stamp = 0;

	function new(body:IrBody) {
		this.body = body;
		edits = body.edits;
	}

	/** The analysis of `body` as it stands: the one cached on it, or a new one, cached. */
	public static function of(body:IrBody):IrBodyAnalysis {
		var known = body.analysis;
		if (known != null && known.edits == body.edits)
			return known;
		var made = new IrBodyAnalysis(body);
		body.analysis = made;
		return made;
	}

	/** Drops the analysis cached on `body`, for a holder that keeps the body past the passes that read it. */
	public static inline function release(body:IrBody):Void
		body.analysis = null;

	// Rows.

	/** The index of the block that links `row`, or -1 when none does. */
	public function blockOf(row:Int):Int {
		var table = rows();
		return row >= 0 && row < table.blocks.length ? table.blocks[row] : -1;
	}

	/** The place of `row` in its block, counting from 0; -1 when no block links it. */
	public function placeOf(row:Int):Int {
		var table = rows();
		return row >= 0 && row < table.places.length ? table.places[row] : -1;
	}

	function rows():IrRowTable {
		var known = rowTable;
		if (known == null)
			rowTable = known = new IrRowTable(body);
		return known;
	}

	// Uses.

	/** How many operands of linked rows read `value`; a phi that reads it from two predecessors counts twice. */
	public function useCount(value:IrValueId):Int {
		var starts = uses().starts;
		return (value:Int) + 1 < starts.length ? starts[(value:Int) + 1] - starts[value] : 0;
	}

	/** The row of use `index` of `value`, in layout order. Debug bindings are not uses. */
	public function useRow(value:IrValueId, index:Int):Int {
		var table = uses();
		return table.rows[table.starts[value] + index];
	}

	function uses():IrUseTable {
		var known = useTable;
		if (known == null)
			useTable = known = new IrUseTable(body);
		return known;
	}

	// Control flow.

	/** The body's graph, with its dominators (`IrBodyGraph`), by block id. */
	public function graph():IrBodyGraph {
		var known = controlFlow;
		if (known == null)
			controlFlow = known = new IrBodyGraph().reset(body);
		return known;
	}

	/**
	 * Whether every path from the entry to row `use` passes row `definition` first: a row dominates itself and the rows after it in
	 * its block. A row after a `BeginTry` of its block does not dominate what the try's handler reaches, since a row between the two
	 * can throw into it.
	 */
	public function dominatesRow(definition:Int, use:Int):Bool {
		var from = blockOf(definition), to = blockOf(use), table = rows();
		if (from < 0 || to < 0)
			return false;
		var place = table.places[definition];
		if (from == to)
			return place <= table.places[use];
		var control = graph(), fromId = body.blockId(from), toId = body.blockId(to);
		if (!control.dominates(fromId, toId))
			return false;
		var tryPlace = table.firstTry[from];
		return tryPlace < 0 || tryPlace > place || !handlerReaches(from, place, toId);
	}

	/** Whether a handler of a `BeginTry` of block `from` (an index) placed before `place` reaches block `target` (an id). */
	function handlerReaches(from:Int, place:Int, target:Int):Bool {
		var control = graph(), marks = visited;
		if (marks == null)
			visited = marks = [];
		stamp++;
		var pending:Array<Int> = [], row = body.firstRow(from), at = 0;
		while (row >= 0 && at < place) {
			if (body.opcode(row) == IrOpcode.BeginTry)
				pending.push(body.auxInt(row, 0));
			row = body.nextRow(row);
			at++;
		}
		while (pending.length > 0) {
			var id = pending.pop();
			if (id == target)
				return true;
			while (marks.length <= id)
				marks.push(0);
			if (marks[id] == stamp || !control.isReachable(id))
				continue;
			marks[id] = stamp;
			for (index in 0...control.successorCount(id))
				pending.push(control.successor(id, index));
		}
		return false;
	}

	/** The loops of the body (`IrLoopForest`). */
	public function loops():IrLoopForest {
		var known = loopForest;
		if (known == null)
			loopForest = known = new IrLoopForest(body, graph());
		return known;
	}
}

/** By row number, the index of its block (-1 for a row no block links) and its place in it; by block, its first try. */
private class IrRowTable {
	public final blocks:Array<Int>;
	public final places:Array<Int>;

	/** Per block index, the place of its first `BeginTry` row, or -1. */
	public final firstTry:Array<Int>;

	public function new(body:IrBody) {
		blocks = [for (_ in 0...body.rowLimit()) -1];
		places = [for (_ in 0...body.rowLimit()) -1];
		firstTry = [for (_ in 0...body.blockCount()) -1];
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block), place = 0;
			while (row >= 0) {
				blocks[row] = block;
				places[row] = place;
				if (firstTry[block] < 0 && body.opcode(row) == IrOpcode.BeginTry)
					firstTry[block] = place;
				place++;
				row = body.nextRow(row);
			}
		}
	}
}

/** The rows that read each value, by value id: those of `value` are `rows[starts[value] ... starts[value + 1]]`. */
private class IrUseTable {
	public final starts:Array<Int>;
	public final rows:Array<Int>;

	public function new(body:IrBody) {
		var limit = body.valueLimit();
		starts = [for (_ in 0...limit + 1) 0];
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				for (index in 0...body.operandCount(row))
					starts[(body.operand(row, index):Int) + 1]++;
				row = body.nextRow(row);
			}
		}
		for (value in 0...limit)
			starts[value + 1] += starts[value];
		var filled = starts.slice(0, limit);
		rows = [for (_ in 0...starts[limit]) 0];
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				for (index in 0...body.operandCount(row)) {
					var value:Int = body.operand(row, index);
					rows[filled[value]++] = row;
				}
				row = body.nextRow(row);
			}
		}
	}
}

/**
 * The natural loops of a body, nested: a loop is a header block and the blocks that reach a back edge into it (an edge from a
 * block the header dominates) without passing the header. Loops by index, outer ones before the ones they hold; blocks by id.
 * An irreducible cycle has no back edge in this sense and is no loop here.
 *
 * Each loop's induction variables are the phis of its header that start from one value outside the loop and step by a constant
 * on every edge from inside it (`Add` or `Sub` of an `I32` constant, the phi itself on the other side).
 */
class IrLoopForest {
	/** By loop, its header block id, its parent loop (-1 for an outermost one) and its depth (1 for an outermost one). */
	final headers:Array<Int> = [];

	final parents:Array<Int> = [];
	final depths:Array<Int> = [];

	/** By block id, the innermost loop that holds it, or -1. */
	final innermost:Array<Int> = [];

	/** By loop, where its induction variables start in the three lists below. */
	final inductionStarts:Array<Int> = [];

	final inductionValues:Array<Int> = [];
	final inductionInitials:Array<Int> = [];
	final inductionSteps:Array<Int> = [];

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
		for (loop in 0...headers.length) {
			inductionStarts.push(inductionValues.length);
			findInductions(body, graph, loop);
		}
		inductionStarts.push(inductionValues.length);
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

	public inline function inductionCount(loop:Int):Int
		return inductionStarts[loop + 1] - inductionStarts[loop];

	/** The phi of induction variable `index` of `loop`. */
	public inline function inductionValue(loop:Int, index:Int):IrValueId
		return IrValueId.of(inductionValues[inductionStarts[loop] + index]);

	/** The value it starts from, which comes from outside the loop. */
	public inline function inductionInitial(loop:Int, index:Int):IrValueId
		return IrValueId.of(inductionInitials[inductionStarts[loop] + index]);

	/** What each iteration adds to it. */
	public inline function inductionStep(loop:Int, index:Int):Int
		return inductionSteps[inductionStarts[loop] + index];

	function findInductions(body:IrBody, graph:IrBodyGraph, loop:Int):Void {
		var header = headers[loop], block = graph.indexOf(header), row = body.firstRow(block);
		while (row >= 0 && body.opcode(row) == IrOpcode.Phi) {
			var phi = body.output(row), initial = -1, step = 0, valid = true;
			for (index in 0...body.operandCount(row)) {
				var from = body.auxInt(row, index), input = body.operand(row, index);
				if (!contains(loop, from)) {
					if (initial >= 0 && initial != (input:Int))
						valid = false;
					initial = input;
					continue;
				}
				var stepped = stepOf(body, phi, input);
				if (stepped == null || step != 0 && stepped != step)
					valid = false;
				else
					step = stepped;
			}
			if (valid && initial >= 0 && step != 0) {
				inductionValues.push(phi);
				inductionInitials.push(initial);
				inductionSteps.push(step);
			}
			row = body.nextRow(row);
		}
	}

	/** The constant `value` adds to `phi` when it is `phi + c`, `c + phi` or `phi - c`; null otherwise. */
	static function stepOf(body:IrBody, phi:IrValueId, value:IrValueId):Null<Int> {
		var row = body.definingRow(value);
		if (row < 0 || body.operandCount(row) != 2)
			return null;
		var left = body.operand(row, 0), right = body.operand(row, 1);
		return switch body.opcode(row) {
			case IrOpcode.Add if (left == phi): constant(body, right);
			case IrOpcode.Add if (right == phi): constant(body, left);
			case IrOpcode.Sub if (left == phi):
				var c = constant(body, right);
				c == null ? null : -c;
			default: null;
		}
	}

	static function constant(body:IrBody, value:IrValueId):Null<Int> {
		var row = body.definingRow(value);
		return row >= 0 && body.opcode(row) == IrOpcode.ConstInt ? body.aux(row) : null;
	}
}
