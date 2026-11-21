// A local inline function called in a lambda that also reads a local of the same name as one its body reads: each name
// keeps the local it named, as in Haxe, though a lambda captures locals by name (the function is then called through
// its closure). The static `k` is what a mix-up would read instead.
class Main {
	static var k = 7;

	static function main() {
		var k = 1;
		inline function f() return k;
		{
			var k = 5;
			var g = () -> f() * 10 + k;
			Sys.println(g());
			var h = () -> k + f() * 100;
			Sys.println(h());
			Sys.println(f() + k);
		}
		var count = 0;
		inline function bump() count++;
		for (i in 0...3) {
			var count = 100;
			var each = () -> {
				bump();
				count += 1;
			};
			each();
			Sys.println(count);
		}
		Sys.println(count);
		Sys.println(Main.k);
	}
}
