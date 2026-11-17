// An abstract's static functions reach the module's functions and variables, as a class's do, and an `extern inline`
// member, in a class or an abstract, is an inline method with a body.
function helper(x:Int):Int
	return x * 2;

var offset = 1;

abstract Stack(Array<Int>) {
	public function new(items:Array<Int>)
		this = items;

	public function size():Int
		return this.length;

	public static function make(n:Int):Stack
		return new Stack([for (i in 0...n) helper(i) + offset]);

	static extern inline function triple(x:Int):Int
		return x * 3;

	public static function made(n:Int):Int
		return triple(make(n).size());
}

enum Shape {
	Square(n:Int);
}

class Util {
	public static extern inline function twice(x:Int):Int
		return helper(x);


}

class Main {
	static function main() {
		var s = Stack.make(3);
		Sys.println(s.size());
		Sys.println(Stack.made(2));
		Sys.println(Util.twice(4));

	}
}
