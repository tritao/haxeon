// Haxe's key/value iteration: `keyValueIterator()` on maps with String, Int and enum keys and on arrays, as an iterator
// object, in loops and comprehensions, and through `KeyValueIterator` and `KeyValueIterable` parameters.
enum Item {
	First;
	Second;
}

class Pairs {
	public function new() {}

	public function keyValueIterator():KeyValueIterator<String, Int>
		return ["a" => 1, "bb" => 2].keyValueIterator();
}

class Main {
	static function describe<K, V>(entries:KeyValueIterator<K, V>, show:K->String):String {
		var parts = [];
		for (entry in entries)
			parts.push(show(entry.key) + "=" + entry.value);
		parts.sort(Reflect.compare);
		return parts.join(",");
	}

	static function weigh(entries:KeyValueIterable<String, Int>):Int {
		var total = 0;
		for (key => value in entries)
			total += key.length * value;
		return total;
	}

	static final lines:Array<String> = [];

	static function println(line:Dynamic):Void
		lines.push(Std.string(line));

	static function main() {
		var names = new Map<String, Int>();
		names["left"] = 20;
		names["right"] = 22;
		var iterator = names.keyValueIterator();
		var total = 0, seen = [];
		while (iterator.hasNext()) {
			var entry = iterator.next();
			seen.push(entry.key);
			total += entry.value;
		}
		seen.sort(Reflect.compare);
		println(seen.join(",") + " " + total);

		var numbers = [3 => "three", 1 => "one", 2 => "two"];
		var keys = [];
		for (key => value in numbers.keyValueIterator())
			keys.push(key + ":" + value);
		keys.sort(Reflect.compare);
		println(keys.join(","));
		println(describe(numbers.keyValueIterator(), key -> Std.string(key * 10)));
		var listed = [for (key => value in numbers.keyValueIterator()) if (key != 2) value + key];
		listed.sort(Reflect.compare);
		println(listed.join(","));
		var inverted = [for (key => value in numbers.keyValueIterator()) value => key];
		println(inverted["two"]);

		var items = new Map<Item, Int>();
		items.set(First, 1);
		items.set(Second, 2);
		var sum = 0;
		for (entry in items.keyValueIterator())
			sum += entry.key == First ? entry.value * 10 : entry.value;
		println(sum);
		println(describe(items.keyValueIterator(), item -> switch item {
			case First: "first";
			case Second: "second";
		}));

		// Each value is read when its entry is reached, and the keys are those of the map when the iterator was made.
		var live = names.keyValueIterator();
		names["left"] = 30;
		names["later"] = 1;
		var liveTotal = 0;
		for (entry in live)
			liveTotal += entry.value;
		println(liveTotal);

		var empty = new Map<String, Int>();
		println(empty.keyValueIterator().hasNext());

		var letters = ["x", "y", "z"];
		var indexed = letters.keyValueIterator(), first = indexed.next();
		println(first.key + first.value + " " + indexed.hasNext());
		var spelled = "";
		for (index => letter in letters.keyValueIterator())
			spelled += index + letter;
		println(spelled);
		println(describe(letters.keyValueIterator(), index -> "#" + index));

		var pairs = 0;
		for (_ => value in new Pairs())
			pairs += value;
		println(pairs + " " + weigh(new Pairs()));

		// What stock Haxe prints for these lines on HashLink.
		var expected = [
			"left,right 42", "1:one,2:two,3:three", "10=one,20=two,30=three", "one1,three3", "2", "12",
			"first=1,second=2", "52", "false", "0x true", "0x1y2z", "#0=x,#1=y,#2=z", "3 5"
		];
		Sys.exit(lines.join("\n") == expected.join("\n") ? 42 : 1);
	}
}
