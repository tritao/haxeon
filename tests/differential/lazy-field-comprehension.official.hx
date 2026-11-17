class Queue {
	public var pending = [for (i in 0...3) i * 2];
	public var labels = [for (i in 0...2) "item" + i];

	public function new() {}
}

class Main {
	static var squares = [for (i in 1...4) i * i];
	static var halves = [for (i in 0...3) i / 2];

	static function main() {
		var queue = new Queue();
		queue.pending.push(10);
		var first:Int = queue.pending[0];
		var label:String = queue.labels[1];
		var square:Int = squares[2];
		var half:Float = halves[1];
		Sys.println(queue.pending);
		Sys.println(first + square);
		Sys.println(label);
		Sys.println(half);
	}
}
