// A callback's result structure whose field mentions a type parameter only the callback fixes (`{xs:Array<S>}`).
class Main {
	static function array<S>(f:Int-> {xs:Array<S>}):Array<S>
		return f(1).xs;

	static function nullable<S>(f:Int-> {xs:Null<S>}):Null<S>
		return f(1).xs;

	static function iterable<S>(f:Int-> {xs:Iterable<S>}):Array<S>
		return [for (x in f(1).xs) x];

	static function field<S>(f:Int-> {a:S}):S
		return f(1).a;

	static function main() {
		Sys.println(array(i -> ({xs: [i]})));
		Sys.println(nullable(i -> ({xs: i})));
		Sys.println(iterable(i -> ({xs: [i]})));
		var p = {a: "s"};
		Sys.println(field(i -> p));
		var q:{a:Int} = {a: 2};
		var r = field(i -> q);
		Sys.println(r + 1);
	}
}
