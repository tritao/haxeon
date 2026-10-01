class Node {
	public var id:Int;

	public function new(id:Int) {
		this.id = id;
	}
}

class Doc {
	public var total = 0;

	public function new() {}

	public function add<T>(item:T):T {
		total++;
		return item;
	}

	public function addNode<T:Node>(node:T):T {
		total += node.id;
		return node;
	}

	function internal():Void {
		add(1);
	}

	public function go():Void {
		internal();
		add("s");
	}
}

function run(callback:() -> Void):Void {
	callback();
}

function bare(doc:Doc):Void {
	doc.add(1);
	doc.addNode(new Node(10));
}

function expressionBody(doc:Doc):Void
	doc.add(2.5);

function main():Int {
	var doc = new Doc();
	bare(doc);
	expressionBody(doc);
	run(() -> doc.add(true));
	function inner():Void {
		doc.add([1]);
	}
	inner();
	doc.go();
	return doc.total + 26;
}
