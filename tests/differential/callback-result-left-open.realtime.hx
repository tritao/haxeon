// A callback whose result fixes nothing (`i -> null`) leaves its type parameter unknown, so Dynamic, as in Haxe.
class Main {
	static function opt<S>(f:Int->Null<S>):Null<S>
		return f(2);

	static function main() {
		var r = opt(i -> null);
		Sys.println(r);
		Sys.println(Lambda.flatMap([], i -> null));
	}
}
