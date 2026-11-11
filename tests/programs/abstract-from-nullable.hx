// A nullable argument converts through the abstract's @:from function for its element type, as in Haxe.
class Source {
	public final value:Float;

	public function new(value:Float)
		this.value = value;
}

class Holder {
	public final amount:Float;

	public function new(amount:Float)
		this.amount = amount;
}

abstract Amount(Holder) {
	inline function new(holder:Holder)
		this = holder;

	@:from public static function ofSource(source:Source):Amount {
		Counters.conversions++;
		return new Amount(new Holder(source.value));
	}

	@:from public static function ofValue(value:Float):Amount
		return new Amount(new Holder(value));

	public inline function total():Float
		return this.amount;
}

function read(amount:Amount):Float
	return amount.total();

function sum(first:Source, ?second:Source):Float {
	var total = read(first);
	if (first != null)
		total += read(second);
	return total;
}

class Counters {
	public static var evaluations:Int = 0;
	public static var conversions:Int = 0;
}

function optional(?amount:Amount):Float
	return amount == null ? 0 : amount.total();

function source(present:Bool):Null<Source> {
	Counters.evaluations++;
	return present ? new Source(21) : null;
}

function main():Int {
	var present:Null<Source> = new Source(21);
	var absent:Null<Source> = null;
	if (optional(present) != 21 || optional(absent) != 0 || optional() != 0)
		return 1;
	if (optional(source(true)) != 21 || optional(source(false)) != 0 || Counters.evaluations != 2)
		return 2;
	var missing:Null<Amount> = absent;
	if (optional(missing) != 0)
		return 5;
	var wrapped:Null<Amount> = present;
	if (optional(wrapped) != 21)
		return 3;

	if (Counters.conversions != 3)
		return 4;
	var left = new Source(10), right = new Source(32);
	return Std.int(sum(left, right));
}
