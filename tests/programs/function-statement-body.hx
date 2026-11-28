// A `function` expression's body may be a statement with no value, as an arrow function's may: an `if` without an
// `else`, or a loop (Haxe types both Void).
function main():Int {
	var total = 0;
	var positive = (x:Int) -> if (x > 0) total += x;
	positive(30);
	positive(-5);
	var each = (values:Array<Int>) -> for (value in values) total += value;
	each([5, 7]);
	var count = 0;
	var countdown = (n:Int) -> while (n > 0) {
		n--;
		count++;
	};
	countdown(3);
	return total + count - 3;
}
