// A nested constructor pattern on a recursive generic enum: the payload Tree<T> is stored as Dynamic, so each nested test casts
// it back to the enum before reading its constructor or fields.
enum Tree<T> {
	Leaf(v:T);
	Node(l:Tree<T>, r:Tree<T>);
	Empty;
}

enum Wrap<T> {
	One(t:Tree<T>);
	Pair(a:Wrap<T>, b:Null<Tree<T>>);
}

class Main {
	static function classify(t:Tree<Int>):String {
		return switch (t) {
			case Node(Leaf(0), _): "zero-left";
			case Node(Leaf(first), Empty) if (first > 10): 'big $first';
			case Node(Leaf(first), Empty): 'left $first';
			case Node(Node(Leaf(a), Leaf(b)), Node(_, Leaf(c))): 'deep ${a + b + c}';
			case Node(Empty, Node(Empty, Empty)): "empties";
			case Node(_, _): "node";
			case Leaf(v): 'leaf $v';
			case Empty: "empty";
		}
	}

	static function leftmost<T>(t:Tree<T>):Null<T> {
		switch (t) {
			case Node(Leaf(v), _):
				return v;
			case Node(l, _):
				return leftmost(l);
			case Leaf(v):
				return v;
			case Empty:
				return null;
		}
	}

	static function wrapped(w:Wrap<String>):String {
		return switch w {
			case One(Node(Leaf(s), _)): 'one $s';
			case Pair(One(Leaf(s)), Leaf(u)): 'pair $s $u';
			case Pair(Pair(_, Node(Leaf(s), _)), null): 'nested $s';
			case _: "other";
		}
	}

	static function main() {
		var samples:Array<Tree<Int>> = [
			Node(Leaf(0), Empty), Node(Leaf(12), Empty), Node(Leaf(5), Empty),
			Node(Node(Leaf(1), Leaf(2)), Node(Empty, Leaf(3))),
			Node(Empty, Node(Empty, Empty)), Node(Empty, Leaf(1)), Leaf(7), Empty
		];
		for (sample in samples)
			Sys.println(classify(sample));
		var annotated:Tree<Int> = Node(Leaf(42), Leaf(1));
		switch (annotated:Tree<Int>) {
			case Node(Leaf(first), _):
				Sys.println('annotated $first');
			default:
				Sys.println("annotated none");
		}
		Sys.println(leftmost(Node(Node(Leaf("deep"), Empty), Empty)));
		Sys.println(leftmost(Node(Leaf(1.5), Empty)));
		Sys.println(leftmost((Empty:Tree<Int>)));
		Sys.println(wrapped(One(Node(Leaf("a"), Empty))));
		Sys.println(wrapped(Pair(One(Leaf("b")), Leaf("c"))));
		Sys.println(wrapped(Pair(Pair(One(Empty), Node(Leaf("d"), Empty)), null)));
		Sys.println(wrapped(Pair(One(Empty), null)));
		var pairs:Array<Array<Tree<Int>>> = [[Node(Leaf(1), Empty), Leaf(2)], [Empty, Node(Leaf(3), Leaf(4))]];
		for (pair in pairs)
			switch [pair[0], pair[1]] {
				case [Node(Leaf(a), _), Leaf(b)]: Sys.println('tuple ${a + b}');
				case [_, Node(Leaf(a), Leaf(b))]: Sys.println('tuple right ${a * b}');
				case _: Sys.println("tuple other");
			}
	}
}
