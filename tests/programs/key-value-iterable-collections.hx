import haxe.ds.ObjectMap;

enum Direction {
	Left;
	Right;
}

enum PayloadKey #if !eval implements Hashable #end {
	Number(value:Int);
}

class Key {
	public final label:String;

	public function new(label:String)
		this.label = label;
}

class Main {
	static function describe<K>(source:KeyValueIterable<K, Int>, label:K->String):String {
		return describeIterator(source.keyValueIterator(), label);
	}

	static function describeIterator<K>(source:KeyValueIterator<K, Int>, label:K->String):String {
		var entries = [];
		for (entry in source)
			entries.push(label(entry.key) + "=" + entry.value);
		entries.sort(Reflect.compare);
		return entries.join(",");
	}

	static function main() {
		var array = [1, 2];
		var ints = [3 => 4, 5 => 6];
		var strings = ["a" => 7, "b" => 8];
		var enums = [Left => 9, Right => 10];
		var payloads = [Number(1) => 17, Number(2) => 18];
		var first = new Key("same");
		var second = new Key("same");
		var objects:Map<Key, Int> = [first => 11, second => 12];
		var explicit = new ObjectMap<Key, Int>();
		explicit.set(first, 13);
		explicit.set(second, 14);

		var lines = [
			describe(array, Std.string),
			describe(ints, Std.string),
			describe(strings, key -> key),
			describe(enums, Std.string),
			describe(payloads, Std.string),
			describe(objects, key -> key.label),
			describe(explicit, key -> key.label)
		];
		var total = 0;
		for (key => value in array)
			total += key * value;
		for (key => value in ints)
			total += key * value;
		for (key => value in strings)
			total += key.length * value;
		for (key => value in enums)
			total += key == Left ? value : -value;
		for (key => value in payloads)
			total += switch key {
				case Number(number): number * value;
			};
		for (key => value in objects)
			total += key == first ? value : -value;
		for (key => value in explicit)
			total += key == first ? value : -value;
		lines.push(Std.string(total));

		var keys = explicit.keys();
		var values = explicit.iterator();
		var pairs = explicit.keyValueIterator();
		var copy = explicit.copy();
		explicit.set(first, 15);
		explicit.set(new Key("later"), 16);
		lines.push(describeIterator(pairs, key -> key.label));
		var keyCount = 0;
		for (key in keys)
			if (key == first || key == second)
				keyCount++;
		var valueSum = 0;
		for (value in values)
			valueSum += value;
		lines.push(keyCount + "=" + valueSum);
		lines.push(describe(copy, key -> key.label));

		var held:KeyValueIterable<Int, Int> = array;
		lines.push(describe(held, Std.string));
		array.push(3);
		lines.push(describe(held, Std.string));

		// Expected output from stock Haxe 4.3.7.
		var expected = [
			"0=1,1=2", "3=4,5=6", "a=7,b=8", "Left=9,Right=10", "Number(1)=17,Number(2)=18", "same=11,same=12",
			"same=13,same=14",
			"109", "same=14,same=15", "2=27", "same=13,same=14", "0=1,1=2", "0=1,1=2,2=3"
		];
		#if eval
		for (line in lines)
			Sys.println(line);
		#end
		Sys.exit(lines.join("\n") == expected.join("\n") ? 42 : 1);
	}
}
