class Pairs {
	final names:Array<String>;

	public function new(names:Array<String>)
		this.names = names;

	public function keyValueIterator():KeyValueIterator<Int, String> {
		var index = 0;
		return {hasNext: () -> index < names.length, next: () -> {key: index, value: names[index++]}};
	}
}

class Main {
	static function describe<K, V>(source:KeyValueIterable<K, V>):String {
		var parts = [];
		for (key => value in source)
			parts.push(key + ":" + value);
		return parts.join(" ");
	}

	static function main() {
		var pairs = new Pairs(["a", "b", "c"]);
		for (index => name in pairs)
			Sys.println(index + name);
		Sys.println(describe(pairs));
		Sys.println([for (index => name in pairs) if (index != 1) name + index]);
		var iterator:KeyValueIterator<Int, String> = pairs.keyValueIterator();
		for (index => name in iterator)
			Sys.println(name + index);
		var map = ["x" => 1];
		for (entry in map.keyValueIterator())
			Sys.println(entry.key + entry.value);
	}
}
