// An empty literal passed to a generic function: its element type is the other arguments', or Dynamic where nothing fixes it.
class Main {
	static function size<T>(a:Array<T>)
		return a.length;

	static function main() {
		Sys.println(size([]));
		Sys.println(Lambda.has([], 3));
		Sys.println(Lambda.indexOf([], "a"));
		Sys.println(Lambda.exists([], x -> true));
		Sys.println(Lambda.fold([], (x, acc) -> acc + 1, 0));
		Sys.println(Lambda.concat([1], []));
		Sys.println(Lambda.concat([], [2]));
		Sys.println(Lambda.map([], x -> x + 1));
	}
}
