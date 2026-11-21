// A local inline function is no value, as in Haxe ("Cannot create closure on inline closure").
class Main {
	static function main() {
		inline function twice(x:Int) return x * 2;
		var f = twice;
		trace(f(2));
	}
}
