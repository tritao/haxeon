// A generic function nothing calls is still typed, as Haxe types it: its error is reported.
interface Measured {
	function measure():Int;
}

class Main {
	static function twice < T:Measured > (value:T):Int return value.measure() + value.missing();

	static function main() {}
}
