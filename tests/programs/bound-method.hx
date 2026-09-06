class Accumulator {
	final base:Int;

	public function new(base:Int) {
		this.base = base;
	}

	public function add(value:Int):Int {
		return base + value;
	}
}

function main():Int {
	var accumulator = new Accumulator(40);
	var add = accumulator.add;
	return add(2);
}
