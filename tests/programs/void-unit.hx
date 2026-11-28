// `Void` as a type argument is the unit type: a generic class or an enum at `Void` takes no argument where it
// would take a `T`, a function with no arguments stands for a `T->U` at `T` = `Void`, and a `Void` payload is equal to
// itself and stores nothing.

class Box<T> {
	public var value:T;

	public function new(value:T)
		this.value = value;

	public function get():T
		return value;
}

enum Maybe<T:Equatable> implements Equatable {
	Some(value:T);
	None;
}

var calls = 0;

function call():Void
	calls++;

function apply<T:Equatable, U>(value:Maybe<T>, f:T->U, fallback:U):U
	return switch value {
		case Some(inner): f(inner);
		case None: fallback;
	}

function main():Int {
	var box = new Box<Void>();
	box.get();
	var some:Maybe<Void> = Some(), other:Maybe<Void> = Some(), none:Maybe<Void> = None;
	if (some != other || some == none)
		return 2;
	if (Type.enumParameters(some).length != 0)
		return 3;
	if (apply(some, () -> 41, 0) != 41 || apply(none, () -> 41, 0) != 0)
		return 4;
	var result:Result<Void, String> = Ok();
	switch result.map(call) {
		case Ok():
		default:
			return 5;
	}
	return calls == 1 ? 42 : 6;
}
