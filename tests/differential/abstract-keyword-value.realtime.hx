// In an abstract's instance method `abstract` is `this` as a value of the abstract: a switch subject, an operand, a
// receiver of the abstract's own methods, and captured by a lambda.
enum abstract Op(Int) {
	var Add = 0;
	var Sub = 1;

	public function label():String
		return switch abstract {
			case Add: "add";
			case Sub: "sub";
			default: "?";
		};

	public function flipped():Op
		return abstract == Add ? Sub : Add;

	public function twice():String
		return abstract.label() + abstract.label();

	public function later():() -> String
		return () -> abstract.label() + "!";
}

abstract Meters(Float) from Float {
	public function plus(other:Meters):Meters
		return this + (cast other:Float);

	public function doubled():Meters
		return abstract.plus(abstract);
}

abstract Bag(Array<Int>) from Array<Int> {
	public function add(v:Int):Void
		this.push(v);

	public function addTwice(v:Int):Int {
		abstract.add(v);
		abstract.add(v);
		return this.length;
	}

	public function size():Int
		return this.length;
}

class Main {
	static function main() {
		var op = Sub;
		Sys.println(op.label() + " " + op.flipped().label() + " " + Add.twice() + " " + op.later()());
		var m:Meters = 1.5;
		Sys.println(m.doubled());
		var b:Bag = [];
		var n = b.addTwice(3);
		Sys.println(n + " " + b.size());
	}
}
