// A typedef may refer to itself through the fields of the structure it declares, as Haxe allows.

typedef TreeNode = {final label:String; final children:Array<TreeNode>;}
typedef Link = {final value:Int; final next:Null<Link>;}
typedef Left = {final id:Int; final right:Null<Right>;}
typedef Right = {final id:Int; final left:Null<Left>;}
typedef Envelope<T> = {final payload:T; final replies:Array<Envelope<T>>;}
typedef OtherTree = {final label:String; final children:Array<OtherTree>;}

function count(node:TreeNode):Int {
	var total = 1;
	for (child in node.children)
		total += count(child);
	return total;
}

function sumLinks(link:Null<Link>):Int {
	if (link == null)
		return 0;
	return link.value + sumLinks(link.next);
}

// A loop condition narrows the variable it tests for the body, as in Haxe.
function walkLinks(first:Null<Link>):Int {
	var total = 0;
	var current = first;
	while (current != null) {
		total += current.value;
		current = current.next;
	}
	// The loop only ends once the condition is false, so the walker is known to be null here.
	return current == null ? total : -1;
}

function payloads(envelope:Envelope<Int>):Int {
	var total = envelope.payload;
	for (reply in envelope.replies)
		total += payloads(reply);
	return total;
}

function main():Int {
	var tree:TreeNode = {
		label: "root",
		children: [{label: "a", children: []}, {label: "b", children: [{label: "c", children: []}]}]
	};
	if (count(tree) != 4)
		return 1;

	var chain:Link = {value: 10, next: {value: 20, next: {value: 12, next: null}}};
	if (sumLinks(chain) != 42)
		return 2;

	if (walkLinks(chain) != 42)
		return 7;

	var mutual:Left = {id: 1, right: {id: 2, left: {id: 3, right: null}}};
	var right = mutual.right;
	if (right == null || right.id != 2)
		return 3;
	var back = right.left;
	if (back == null || back.id != 3)
		return 4;

	var thread:Envelope<Int> = {payload: 1, replies: [{payload: 2, replies: []}, {payload: 3, replies: [{payload: 4, replies: []}]}]};
	if (payloads(thread) != 10)
		return 5;

	// Two typedefs with the same shape are interchangeable, recursive or not.
	var other:OtherTree = {label: "x", children: []};
	var asTree:TreeNode = other;
	if (asTree.label != "x")
		return 6;

	return 42;
}
