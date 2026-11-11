abstract Amount(Float) {
	function new(value:Float)
		this = value;

	@:from public static function ofFloat(value:Float):Amount
		return new Amount(value + 1);

	public function total():Float
		return this;
}

abstract Exact(Float) {
	function new(value:Float)
		this = value;

	// Even when Float comes first, the exact Int conversion wins.
	@:from public static function ofFloat(value:Float):Exact
		return new Exact(value + 100);

	@:from public static function ofInt(value:Int):Exact
		return new Exact(value + 1);

	public function total():Float
		return this;
}

function read(value:Amount):Int
	return Std.int(value.total());

function exact(value:Exact):Int
	return Std.int(value.total());

function optional(?value:Amount):Int
	return value == null ? 0 : Std.int(value.total());

function main():Int {
	if (read(41) != 42 || read(41.0) != 42 || exact(41) != 42)
		return 1;
	var value:Null<Int> = 41;
	var absent:Null<Int> = null;
	if (optional(value) != 42 || optional(absent) != 0)
		return 2;
	return 42;
}
