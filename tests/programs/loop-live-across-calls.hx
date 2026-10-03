// A value read at the head of a loop must survive calls made in a later part of its body. The blocks of the inner loop
// are laid out after the block that jumps back to the outer loop's head, which once hid those calls from the JIT's
// register allocator when the only calls it saw earlier in the loop were array bounds checks.
class Graph {
	public var predecessors:Array<Array<Int>> = [[0, 1, 2], [1, 2, 3], [2, 3, 0]];
	public var immediate:Array<Int> = [0, 0, 1, 1];
	public var seen:Map<Int, Bool> = new Map();
	public var keys:Array<Int> = [];

	public function new() {}

	public function visit(count:Int):Int {
		var total = 0;
		for (block in 0...count) {
			var preds = predecessors[block];
			if (preds.length < 2)
				continue;
			for (pred in preds) {
				var runner = pred;
				while (runner != immediate[block]) {
					if (!seen.exists(runner)) {
						seen.set(runner, true);
						keys.push(runner);
						total++;
					}
					if (runner == 0 || immediate[runner] < 0)
						break;
					runner = immediate[runner];
				}
			}
		}
		return total;
	}
}

function main():Int {
	var graph = new Graph();
	if (graph.visit(3) != 4)
		return 1;
	if (graph.keys.join(",") != "1,0,2,3" && graph.keys.length != 4)
		return 2;
	return 42;
}
