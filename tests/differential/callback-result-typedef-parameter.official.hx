// A callback's result written through a generic typedef fixes the call's type parameter (`Entry<T>`).
typedef Entry<T> = {key:String, value:T};

class Main {
	static function build<T>(n:Int, f:Int->Entry<T>):Array<Entry<T>>
		return [for (i in 0...n) f(i)];

	static function main() {
		var r = Lambda.map([1, 2], x -> ({v: x, s: "n" + x}));
		Sys.println(r[1].s);
		var e = build(2, i -> ({key: "k" + i, value: i * 3}));
		Sys.println(e[1].value + 1);
	}
}
