class Box {
	public var value:Int;

	public function new(value:Int) {
		this.value = value;
	}
}

function identity<T>(value:T):T {
	return value;
}

function branch(flag:Bool):Int {
	var chosen;
	if (flag)
		chosen = 10;
	else
		chosen = 20;
	return chosen;
}

function text(flag:Bool):String {
	var label;
	if (flag)
		label = "yes";
	else
		label = "no";
	return label;
}

function selected(kind:Int):Int {
	var result;
	switch kind {
		case 0:
			result = 1;
		default:
			result = 5;
	}
	return result;
}

function guarded():Int {
	var parsed;
	try {
		parsed = Std.parseInt("7");
	} catch (error:Dynamic) {
		parsed = -1;
	}
	return parsed;
}

function main():Int {
	var first, second;
	first = 3;
	second = first + 4;
	var box;
	box = new Box(second);
	var generic;
	generic = identity(box.value);
	var total = branch(true) + branch(false) + selected(0) + selected(3) + guarded();
	if (text(true) != "yes" || text(false) != "no")
		return 1;
	return total + generic + 1 - 9;
}
