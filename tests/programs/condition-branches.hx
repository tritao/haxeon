class Probe {
	public static var calls:Int = 0;

	public static function yes():Bool {
		calls++;
		return true;
	}

	public static function no():Bool {
		calls++;
		return false;
	}
}

class Box {
	public var count:Null<Int>;
	public var copy:Null<Int>;
	public var label:String;

	public function new(count:Null<Int>, label:String) {
		this.count = count;
		this.label = label;
	}

	public function mirror():Void {
		if (count != null)
			copy = count;
	}
}

function pick(a:Bool, b:Bool, c:Bool):Int {
	if (a && b || c)
		return 1;
	if (!(a || b) && !c)
		return 2;
	return a && !b ? 3 : 4;
}

function main():Int {
	// All combinations of && || ! agree with their truth table.
	if (pick(true, true, false) != 1 || pick(false, false, true) != 1 || pick(false, false, false) != 2 || pick(true, false, false) != 3
		|| pick(false, true, false) != 4)
		return 1;

	// Operands short-circuit: the right side runs only when needed, in source order.
	Probe.calls = 0;
	var result = Probe.no() && Probe.yes();
	if (result || Probe.calls != 1)
		return 2;
	Probe.calls = 0;
	if (!(Probe.yes() || Probe.no()) || Probe.calls != 1)
		return 3;
	Probe.calls = 0;
	if (Probe.no() || Probe.yes() && Probe.no() || Probe.calls != 3)
		return 4;

	// Null tests on boxed values: zero is not null, null is not zero.
	var some:Null<Int> = 0;
	var none:Null<Int> = null;
	if (some == null || none != null || some != 0)
		return 5;
	var text:String = null;
	var word = "w";
	if (text != null || word == null || (text == null && word != null) == false)
		return 6;

	// A narrowed value assigned to another nullable field keeps its value; null stays null.
	var withValue = new Box(7, "a");
	var withoutValue = new Box(null, "b");
	withValue.mirror();
	withoutValue.mirror();
	if (withValue.copy != 7 || withoutValue.copy != null)
		return 7;

	// Variables assigned inside a condition are visible on every path.
	var index = 0;
	var steps = 0;
	while (index < 10 && (index = index + 3) > 0 && steps < 99)
		steps++;
	if (index != 12 || steps != 4)
		return 8;

	// Compound conditions in loops, with break and continue.
	var total = 0;
	for (i in 0...20) {
		if (i % 2 == 0 || i > 15)
			continue;
		if (!(i < 9 || i == 11))
			break;
		total += i;
	}
	if (total != 1 + 3 + 5 + 7)
		return 9;
	var chosen = some != null && none == null ? (some == 0 ? 10 : 20) : 30;
	if (chosen != 10)
		return 10;
	return 42;
}
