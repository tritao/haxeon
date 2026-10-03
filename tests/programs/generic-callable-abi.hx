class Value {
	public final number:Int;

	public function new(number:Int)
		this.number = number;
}

class Comparator<T> {
	final compare:Null<T->T->Bool>;

	public function new(?compare:T->T->Bool)
		this.compare = compare;

	public function equal(left:T, right:T):Bool
		return compare == null ? left == right : compare(left, right);

	public function hasComparator():Bool
		return compare != null;
}

class Store<T> {
	public var operation:Null<T->T>;

	public function new(?operation:T->T)
		this.operation = operation;

	public function apply(value:T):T
		return operation == null ? value : operation(value);
}

class Functions {
	public static var calls = 0;
	public static final comparator = new Comparator<Value>(compare);

	public static function compare(left:Value, right:Value):Bool
		return left.number == right.number;

	public static function optional(enabled:Bool):Null<Value->Value->Bool> {
		calls++;
		return enabled ? compare : null;
	}

	public static function shift(value:Float):Float
		return value + 0.5;

	public static function wrap(operation:Int->Int):Int->Int
		return value -> operation(value) + 2;
}

function main():Int {
	if (!Functions.comparator.equal(new Value(42), new Value(42)))
		return 8;
	var comparator = new Comparator<Value>(Functions.optional(true));
	if (Functions.calls != 1
		|| !comparator.hasComparator()
		|| !comparator.equal(new Value(42), new Value(42))
		|| comparator.equal(new Value(1), new Value(2)))
		return 1;
	var missing = new Comparator<Value>(Functions.optional(false));
	var shared = new Value(42);
	if (Functions.calls != 2
		|| missing.hasComparator()
		|| !missing.equal(shared, shared)
		|| missing.equal(shared, new Value(42)))
		return 2;
	var integers = new Store<Int>(value -> value + 2);
	if (integers.apply(40) != 42)
		return 3;
	integers.operation = value -> value + 3;
	if (integers.apply(39) != 42)
		return 4;
	integers.operation = null;
	if (integers.operation != null || integers.apply(42) != 42)
		return 5;
	var floats = new Store<Float>(Functions.shift);
	if (floats.apply(41.5) != 42.0)
		return 6;
	var nested = new Store<Int->Int>(Functions.wrap);
	var transformed = nested.apply(value -> value + 1);
	if (transformed(39) != 42)
		return 7;
	return 42;
}
