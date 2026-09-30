@:value
class Lines {
	public var height:Null<Float>;
	public var label:String;
	public var count:Int;

	public function new(height:Null<Float> = null, label:String = "", count:Int = 0) {
		this.height = height;
		this.label = label;
		this.count = count;
	}
}

class Node {
	public final lines:Lines;
	public var tag:Int;

	public function new() {
		lines = new Lines();
		tag = 7;
	}
}

function churn(seed:Int):Int {
	var total = 0;
	for (i in 0...200000) {
		var values = [seed + i, i + 1, i + 2];
		total += values.length + ("x" + i).length;
	}
	return total;
}

function main():Int {
	var failures = 0;
	var node = new Node();
	var source = new Lines(Std.parseFloat("2.25") + 1.0, "line" + Std.parseInt("5"), 4);
	node.lines.height = source.height;
	node.lines.label = source.label;
	node.lines.count = source.count;
	var total = 0;
	for (round in 0...6)
		total += churn(round);
	if (total == 0)
		failures += 1;
	if (node.lines.height != 3.25)
		failures += 2;
	if (node.lines.label != "line5")
		failures += 4;
	if (node.lines.count != 4 || node.tag != 7)
		failures += 8;
	return failures == 0 ? 42 : failures;
}
