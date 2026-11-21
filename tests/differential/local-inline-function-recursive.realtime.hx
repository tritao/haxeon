// A local inline function cannot call itself, as in Haxe ("Inline function cannot be recursive").
class Main {
	static function main() {
		inline function fact(m:Int):Int return m <= 1 ? 1 : m * fact(m - 1);
		trace(fact(4));
	}
}
