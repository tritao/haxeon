// An empty array literal's element type is fixed by the first use that fixes it, as in Haxe: a push (even of another
// empty array, or from inside a lambda), the typed parameter it is passed to, or the value `indexOf` compares with.
class Main {
	static function fill(list:Array<Int>):Void
		for (i in 0...4)
			list.push(i * i);

	static function each(list:Array<Int>, f:Int->Void):Void
		for (v in list)
			f(v);

	static function main():Void {
		var squares = [];
		fill(squares);
		Sys.println(squares.join(","));

		var rows = [];
		var row = [];
		row.push(3);
		rows.push(row);
		rows.push([4, 5]);
		Sys.println(rows.length + " " + rows[0][0] + " " + rows[1][1]);

		var doubled = [];
		each([1, 2, 3], v -> doubled.push(v * 2));
		Sys.println(doubled.join(","));

		var sources = [];
		for (source in "a,b,a,c".split(","))
			if (sources.indexOf(source) < 0)
				sources.push(source);
		Sys.println(sources.join("|"));

		var seen = [];
		var had = seen.contains(3);
		seen.push(3);
		Sys.println(had + " " + seen.contains(3));

		var words = [];
		words.push("x");
		words.unshift("w");
		Sys.println(words.join("") + " " + words[0].length);
	}
}
