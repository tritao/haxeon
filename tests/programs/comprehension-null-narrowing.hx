// A comprehension's value is computed only where its condition holds, so it sees what the
// condition proves: here, that an element of an array of nullable records is not null.
function main():Int {
	var parts:Array<Null<{node:Int}>> = [{node: 2}, null, {node: 40}];
	var nodes = [for (part in parts) if (part != null) part.node];
	var keyed = [for (part in parts) if (part != null) part.node => part.node + 1];
	var total = 0;
	for (node in nodes)
		total += node;
	return total + (keyed.get(40) == 41 ? 0 : 100);
}
