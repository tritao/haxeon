// A switch without a default covers an enum through patterns nested at any depth: each payload position is split into its
// values, so `Bad(Wrapped(A))`, `Bad(Wrapped(B(_)))` and `Bad(Plain(_))` cover `Bad`.
enum Inner {
	A;
	B(at:Int);
}

enum Outer {
	Wrapped(inner:Inner);
	Plain(value:Int);
	Pair(left:Inner, right:Bool);
}

enum Reply<T, E> {
	Good(value:T);
	Bad(error:E);
}

function describe(reply:Reply<Int, Outer>):String
	return switch reply {
		case Good(value): "good " + value;
		case Bad(Wrapped(A)): "a";
		case Bad(Wrapped(B(at))): "b" + at;
		case Bad(Plain(value)): "plain " + value;
		case Bad(Pair(A, true)): "pair a true";
		case Bad(Pair(A, false)): "pair a false";
		case Bad(Pair(B(_), _)): "pair b";
	}

function count(reply:Reply<Int, Outer>):Int {
	var total = 0;
	switch reply {
		case Good(_):
			total = 1;
		case Bad(Wrapped(B(_))):
			total = 2;
		case Bad(Wrapped(A) | Plain(_)):
			total = 3;
		case Bad(Pair(_, _)):
			total = 4;
	}
	return total;
}

function main():Int {
	if (describe(Good(1)) != "good 1" || describe(Bad(Wrapped(B(2)))) != "b2"
		|| describe(Bad(Pair(A, false))) != "pair a false")
		return 1;
	if (describe(Bad(Pair(B(1), true))) != "pair b" || describe(Bad(Plain(4))) != "plain 4")
		return 2;
	if (count(Bad(Wrapped(A))) != 3 || count(Bad(Pair(B(0), true))) != 4 || count(Good(0)) != 1)
		return 3;
	return 42;
}
