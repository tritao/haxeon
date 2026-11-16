package modulevars;

// Module-level variables: static fields of the module's class (here none is declared, so one is made for them).
var hits = 0;
final base = 10;
// Inferred through a module-level function's declared result.
final derived = base * 2 + offset();
private var secret = 3;
var names:Array<String> = [];

function offset():Int
	return 1;

function record():Int {
	hits++;
	hits += 1;
	names.push("record");
	return hits;
}

class Counter {
	public var step = 5;

	public function new() {}

	/** A module-level variable from a method of another class in the module. */
	public function advance():Int {
		hits = hits + step + secret;
		return hits;
	}
}

class Shadow {
	var hits = 100;

	public function new() {}

	/** The class's own member wins over the module-level variable of the same name, for a read and for a write. */
	public function bump():Int {
		hits += 1;
		hits = hits + 1;
		return hits;
	}
}
