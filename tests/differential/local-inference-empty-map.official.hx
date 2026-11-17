// `new Map()` takes its key and value types from its first `set`, as in Haxe.
class Box {
	public final label:String;

	public function new(label:String)
		this.label = label;
}

class Main {
	static function counts(words:Array<String>):Map<String, Int> {
		var seen = new Map();
		for (word in words)
			seen.set(word, (seen.get(word) ?? 0) + 1);
		return seen;
	}

	static function main():Void {
		var seen = counts(["a", "b", "a", "c", "a"]);
		Sys.println(seen.get("a") + " " + seen.get("b") + " " + seen.exists("d"));

		var groups = new Map();
		groups.set(3, [new Box("a"), new Box("bc")]);
		groups.set(7, [new Box("def")]);
		var total = 0;
		for (boxes in groups)
			for (box in boxes)
				total += box.label.length;
		Sys.println(total);

		var squares = new Map();
		for (i in 0...4)
			squares[i] = i * i;
		var keys = [for (key in squares.keys()) key];
		keys.sort((a, b) -> a - b);
		Sys.println([for (key in keys) squares[key]].join(","));
	}
}
