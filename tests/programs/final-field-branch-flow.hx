class Part {
	public final value:Int = 7;
	public function new() {}
}

class Machine {
	public final part:Null<Part>;
	var counter:Int = 0;
	public function new(present:Bool) {
		part = present ? new Part() : null;
		if (part == null) {} else {
			if (part.value < 0) throw "invalid part";
			touch();
			counter = part.value;
		}
	}
	function touch():Void counter++;
	public function check(flag:Bool, mode:Int):Int {
		if (part == null) return 0;
		if (flag) counter++ else counter += 2;
		touch();
		var value = part.value;
		switch mode {case 0: counter++; default: counter += 2;}
		touch();
		value += part.value;
		for (i in 0...2) if (flag) counter++ else counter += 2;
		touch();
		return value + part.value;
	}
}

function main():Int {
	return new Machine(true).check(true, 0) + new Machine(true).check(false, 1)
		+ new Machine(false).check(true, 0);
}
