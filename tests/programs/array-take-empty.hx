// pop and shift return Null<T>, null on an empty array, as in Haxe; read as Int that null is 0.
class Item {
	public final v:Int;

	public function new(v:Int)
		this.v = v;
}

function main():Int {
	var ints:Array<Int> = [];
	if (ints.pop() != null || ints.shift() != null)
		return 1;
	var zero:Int = ints.pop();
	var items:Array<Item> = [];
	if (items.pop() != null || items.shift() != null)
		return 2;
	var names = ["a"];
	var first = names.shift();
	if (first != "a" || names.shift() != null)
		return 3;
	var stack = [30, 10];
	var calls = 0;
	function source():Array<Int> {
		calls++;
		return stack;
	}
	var top:Int = source().pop();
	var total = 0;
	while (stack.length > 0)
		total += stack.pop();
	return top + total + 2 + zero - calls + 1;
}
