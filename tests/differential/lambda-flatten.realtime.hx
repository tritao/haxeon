// Lambda.flatten and Lambda.flatMap over arrays, with callbacks whose arrays are iterated as Iterable results.
class Main {
	static function main():Void {
		Sys.println(Lambda.flatten([[1, 2], [], [3]]));
		var words = [["x"], ["y", "z"]];
		Sys.println(Lambda.flatten(words).join("-"));
		Sys.println(Lambda.flatMap(["ab", "c"], text -> text.split("")));
		Sys.println(Lambda.flatMap([1, 2, 3], count -> [for (_ in 0...count) count]));
		var lengths = Lambda.flatMap(["one", "three"], word -> [word.length, -word.length]);
		lengths.push(0);
		Sys.println(lengths);
	}
}
