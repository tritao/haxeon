// A local map nothing else can reach keeps what `exists` proved across calls that could not have touched it.

class Counter {
	public var count = 0;

	public function new() {}

	public function bump():Void {
		count++;
	}
}

function lookup(names:Array<String>):Int {
	var ages:Map<String, Int> = new Map();
	var counter = new Counter();
	ages.set("ada", 36);
	ages.set("alan", 41);
	var total = 0;
	for (name in names) {
		if (!ages.exists(name))
			continue;
		counter.bump();
		total += ages.get(name);
	}
	return total + counter.count;
}

function main():Int {
	// 36 + 41 for the two known names and one bump each.
	return lookup(["ada", "grace", "alan"]) == 79 ? 42 : 1;
}
