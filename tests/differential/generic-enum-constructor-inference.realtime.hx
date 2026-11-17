import haxe.ds.Option;

// A generic enum constructor call infers its type parameters from its arguments and from the expected type, as a generic
// function call does: nested constructors, constructors without arguments, arrays of constructors, and a local whose
// parameter is fixed later.
enum Ins {
	Move(steps:Int);
	Turn(degrees:Float);
	Halt;
}

enum Tree<T> {
	Leaf(value:T);
	Node(left:Tree<T>, right:Tree<T>);
	Empty;
}

enum Pair<A, B> {
	Both(first:A, second:B);
	OnlyFirst(first:A);
	Neither;
}

class Main {
	static function describe(ins:Ins):String
		return switch ins {
			case Move(n): 'move $n';
			case Turn(d): 'turn $d';
			case Halt: "halt";
		};

	static function program(o:Option<Ins>):String
		return switch o {
			case Some(Move(n)): 'some move $n';
			case Some(other): 'some ${describe(other)}';
			case None: "none";
		};

	static function sum(tree:Tree<Int>):Int
		return switch tree {
			case Leaf(value): value;
			case Node(left, right): sum(left) + sum(right);
			case Empty: 0;
		};

	static function main() {
		// Nested: the argument fixes the parameter, so the pattern sees Option<Ins>.
		var o = Some(Move(4));
		switch o {
			case Some(Move(n)): Sys.println('nested $n');
			case Some(_): Sys.println("other");
			case None: Sys.println("none");
		}
		Sys.println(program(o));
		// An array of constructors.
		var list = [Some(Halt), Some(Turn(1.5)), None];
		for (item in list)
			switch item {
				case Some(Halt): Sys.println("halt in list");
				case Some(Turn(d)): Sys.println('turn $d in list');
				case Some(Move(_)): Sys.println("move in list");
				case None: Sys.println("none in list");
			}
		var only = [Some(Halt)];
		switch only[0] {
			case Some(Halt): Sys.println("only halt");
			default: Sys.println("only other");
		}
		// No arguments: from the expected type, and from a later use.
		var expected:Option<Ins> = None;
		Sys.println(program(expected));
		var later = None;
		later = Some(Turn(2.5));
		Sys.println(program(later));
		var unused = None;
		Sys.println(unused == None ? "unused none" : "unused some");
		// A recursive generic enum, and several parameters.
		var tree = Node(Leaf(1), Node(Leaf(2), Empty));
		Sys.println(sum(tree));
		switch tree {
			case Node(left, _): Sys.println('left sum ${sum(left)}');
			default: Sys.println("no left");
		}
		var pair = Both("a", Move(3));
		switch pair {
			case Both(name, Move(n)): Sys.println('$name moves $n');
			default: Sys.println("pair other");
		}
		var partial = OnlyFirst(7);
		switch partial {
			case OnlyFirst(value): Sys.println('only first ${value + 1}');
			default: Sys.println("partial other");
		}
		// A constructor as a function argument and as a return value.
		Sys.println(program(Some(Move(9))));
		var make = () -> Some(Turn(0.5));
		Sys.println(program(make()));
		// A null argument leaves the parameter to what the value meets.
		var blank = Some(null);
		blank = Some(Halt);
		Sys.println(program(blank));
		// Nested from the inside out: the first argument is open until the second fixes it.
		var right = Node(Empty, Leaf(5));
		Sys.println(sum(right));
		var deep = [Some(Some(Move(2))), None];
		switch deep[0] {
			case Some(Some(Move(n))): Sys.println('deep $n');
			default: Sys.println("deep other");
		}
	}
}
