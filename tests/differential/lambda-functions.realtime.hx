// Haxe's Lambda over arrays and maps, called as static functions.
class Main {
	static function main():Void {
		var values = [3, 1, 4, 1, 5];
		Sys.println(Lambda.fold(values, (x, total) -> x + total, 0));
		Sys.println(Lambda.foldi(values, (x, total, index) -> total + x * index, 0));
		Sys.println(Lambda.map(values, x -> x * 2));
		Sys.println(Lambda.mapi(values, (index, x) -> index + x));
		Sys.println(Lambda.filter(values, x -> x > 2));
		Sys.println(Lambda.foreach(values, x -> x > 0));
		Sys.println(Lambda.empty(values));
		Sys.println(Lambda.indexOf(values, 4));
		Sys.println(Lambda.indexOf(values, 9));
		Sys.println(Lambda.findIndex(values, x -> x == 5));
		Sys.println(Lambda.concat(values, [9]));
		Sys.println(Lambda.array(values).length);
		Lambda.iter(values, x -> Sys.print(x));
		Sys.println("");
		var counts = ["a" => 2, "b" => 3];
		Sys.println(Lambda.fold(counts, (x, total) -> x + total, 0));
		Sys.println(Lambda.count(counts));
	}
}
