class Countdown {
	var remaining:Int;

	public function new(start:Int) {
		remaining = start;
	}

	public function hasNext():Bool {
		return remaining > 0;
	}

	public function next():Int {
		return remaining--;
	}
}

function main():Void {
	for (i in 0...2)
		Sys.println(i);
	for (index => fruit in ["pear", "plum"])
		Sys.println('$index: $fruit');
	for (number in new Countdown(2))
		Sys.println('T-$number');
}
