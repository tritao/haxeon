// An enum's method may declare type parameters of its own, inferred at each call from its arguments and expected result as
// a generic class method's are; its body is typed once per enum and method type arguments.
enum Slot<T> {
	Full(value:T);
	Empty;

	public static function of<A>(value:Null<A>):Slot<A>
		return value == null ? Empty : Full(value);

	public function map<U>(f:T->U):Slot<U>
		return switch this {
			case Full(value): Full(f(value));
			case Empty: Empty;
		}

	public function then<U>(f:T->Slot<U>):Slot<U>
		return switch this {
			case Full(value): f(value);
			case Empty: Empty;
		}

	/** Calls a generic sibling on `this` without naming it. */
	public function describe<U>(f:T->U, prefix:String = "="):String
		return switch map(f) {
			case Full(value): prefix + value;
			case Empty: "empty";
		}

	/** Only the expected result fixes `U`. */
	public function cleared<U>():Slot<U>
		return Empty;

	public function or(fallback:T):T
		return switch this {
			case Full(value): value;
			case Empty: fallback;
		}
}

interface Measured {
	function meters():Float;
}

class Rope implements Measured {
	public function new() {}

	public function meters():Float
		return 10;
}

enum Unit {
	Meter;
	Foot;

	/** A method's own constraint is checked at each call. */
	public function convert<M:Measured>(value:M):Float
		return switch this {
			case Meter: value.meters();
			case Foot: value.meters() / 0.3048;
		}
}

function main():Int {
	var count:Slot<Int> = Full(20);
	if (count.map(n -> n * 2).or(0) != 40)
		return 1;
	if (count.map(n -> "n" + n).or("") != "n20")
		return 2;
	var none:Slot<Int> = Empty;
	if (none.map(n -> n + 1).or(-1) != -1)
		return 3;
	var halves = count.then(n -> n % 2 == 0 ? Full(n / 2) : Empty);
	if (halves.or(0.0) != 10.0)
		return 4;
	if (Slot.of("x").or("y") != "x" || Slot.of((null:Null<String>)).or("y") != "y")
		return 5;
	if (count.describe(n -> n + 1) != "=21" || count.describe(n -> n, ":") != ":20" || none.describe(n -> n) != "empty")
		return 6;
	var cleared:Slot<String> = count.cleared();
	if (cleared.or("none") != "none")
		return 7;
	if (Meter.convert(new Rope()) != 10 || Foot.convert(new Rope()) != 10 / 0.3048)
		return 8;
	return 42;
}
