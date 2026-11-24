// `for (key => value in x)` over a custom type, as Haxe types it: through `x.keyValueIterator()`, or over `x` itself when it is
// an iterator of `{key, value}`; Haxe's KeyValueIterator and KeyValueIterable types; and Map's keyValueIterator().
class Pairs {
	final keys:Array<String>;
	final values:Array<Int>;

	public function new(keys:Array<String>, values:Array<Int>) {
		this.keys = keys;
		this.values = values;
	}

	public function keyValueIterator():KeyValueIterator<String, Int> {
		var index = 0;
		return {hasNext: () -> index < keys.length,
			next: () -> {
				var entry = {key: keys[index], value: values[index]};
				index++;
				return entry;
			}
		};
	}
}

class Entry {
	public var key:Int;
	public var value:String;

	public function new(key:Int, value:String) {
		this.key = key;
		this.value = value;
	}
}

// A class that is its own iterator, whose entries are a class with `key` and `value` fields.
class Countdown {
	var remaining:Int;

	public function new(remaining:Int)
		this.remaining = remaining;

	public function hasNext():Bool
		return remaining > 0;

	public function next():Entry
		return new Entry(remaining, "#" + remaining--);
}

class Inherited extends Pairs {
	public function new() {
		super(["x"], [9]);
	}
}

function join<K, V>(source:KeyValueIterable<K, V>):String {
	var parts:Array<String> = [];
	for (key => value in source)
		parts.push(Std.string(key) + "=" + Std.string(value));
	return parts.join(",");
}

function total(iterator:KeyValueIterator<String, Int>):Int {
	var sum = 0;
	for (key => value in iterator)
		sum += key.length * value;
	return sum;
}

function check(failures:Array<String>, label:String, actual:Dynamic, expected:String):Void {
	if (Std.string(actual) != expected)
		failures.push(label + ": " + Std.string(actual) + " != " + expected);
}

function main():Int {
	var failures:Array<String> = [];
	var pairs = new Pairs(["a", "bb", "ccc"], [1, 2, 3]);
	var seen = "";
	for (key => value in pairs)
		seen += key + value + ";";
	check(failures, "class", seen, "a1;bb2;ccc3;");
	check(failures, "iterable", join(pairs), "a=1,bb=2,ccc=3");
	check(failures, "inherited", join(new Inherited()), "x=9");
	check(failures, "iterator", total(pairs.keyValueIterator()), "14");
	var anonymous = {keyValueIterator: () -> new Pairs(["q"], [4]).keyValueIterator()};
	check(failures, "structure", join(anonymous), "q=4");
	var down = "";
	for (key => value in new Countdown(3))
		down += key + value;
	check(failures, "own iterator", down, "3#32#21#1");
	// Each step binds fresh variables, and break and continue leave or skip the step.
	var closures:Array<() -> String> = [];
	for (key => value in pairs) {
		if (value == 2)
			continue;
		closures.push(() -> key + value);
		if (value == 3)
			break;
	}
	check(failures, "fresh bindings", [for (f in closures) f()], "[a1,ccc3]");
	// The iterable is evaluated once.
	var made = 0;
	function make():Pairs {
		made++;
		return pairs;
	}
	var count = 0;
	for (_ => _ in make())
		count++;
	check(failures, "evaluated once", made + " " + count, "1 3");
	// An arrow function whose body is an object literal gives that object.
	var step = 0;
	var literal:KeyValueIterator<Int, Int> = {hasNext: () -> step < 2, next: () -> {key: step, value: step++ * 10}};
	var stepped = "";
	for (key => value in literal)
		stepped += key + ":" + value + ";";
	check(failures, "arrow object literal", stepped, "0:0;1:10;");
	// Comprehensions loop over the entries alike.
	check(failures, "array comprehension", [for (key => value in pairs) if (value > 1) key + value], "[bb2,ccc3]");
	var doubled = [for (key => value in pairs) key => value * 2];
	check(failures, "map comprehension", (doubled.get("bb") ?? 0) + (doubled.get("ccc") ?? 0), "10");
	check(failures, "nested comprehension", [for (key => value in pairs) for (index in 0...value) key],
		"[a,bb,bb,ccc,ccc,ccc]");
	var map:Map<String, Int> = ["one" => 1, "two" => 2];
	var entries = [for (entry in map.keyValueIterator()) entry.key + entry.value];
	entries.sort(Reflect.compare);
	check(failures, "map entries", entries, "[one1,two2]");
	check(failures, "map iterator", total(map.keyValueIterator()), "9");
	var scores:Map<Int, Float> = [1 => 0.5, 2 => 1.5];
	var weighted = 0.0;
	for (key => value in scores.keyValueIterator())
		weighted += key * value;
	check(failures, "map scalar entries", weighted, "3.5");
	return failures.length == 0 ? 42 : failures.length;
}
