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

	@:from public static function ofSource(source:Source):Amount
		return new Amount(new Holder(source.value));

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

function main():Int {
	var left = new Source(10), right = new Source(32);
	return Std.int(sum(left, right));
}
