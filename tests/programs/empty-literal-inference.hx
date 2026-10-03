class Item {
	public var weight:Int;

	public function new(weight:Int) {
		this.weight = weight;
	}
}

// The element type of an empty array, and the key and value types of an untyped map, come from what is stored in them.
function fromParameter(x:Int):Int {
	var values = [];
	values.push(x);
	values.push(x + 1);
	return values[0] + values[1];
}

function fromComparison(x:Int):Bool {
	var flags = [];
	flags.push(x == 1);
	return flags[0];
}

function fromLoop():Int {
	var doubled = [];
	for (i in 0...4)
		doubled.push(i * 2);
	var total = 0;
	for (value in doubled)
		total += value;
	return total;
}

function fromField(item:Item):Int {
	var weights = [];
	weights.push(item.weight);
	return weights[0];
}

function fromString(n:Int):String {
	var labels = [];
	labels.push("n" + n);
	return labels[0];
}

function fromAssignment():Int {
	var values = [];
	values = [3, 4, 5];
	return values.length;
}

function fromElement():Int {
	var values = [];
	values[0] = 7;
	return values[0];
}

function fromClosure():Int {
	var seen = [];
	var add = (value:Int) -> seen.push(value);
	add(5);
	add(6);
	return seen.length;
}

function fromCatch():Int {
	var errors = [];
	try {
		throw "boom";
	} catch (error:Dynamic) {
		errors.push(Std.string(error));
	}
	return errors[0].length;
}

function fromUnshift():Int {
	var values = [];
	values.unshift(2.5);
	return Std.int(values[0] * 2);
}

function fromMap():Int {
	var scores = new Map();
	for (i in 0...3)
		scores.set(i, i * 10);
	var found = scores.get(2);
	return found != null ? found : -1;
}

function fromMapAssignment(key:String, value:Int):Int {
	var scores = new Map();
	scores[key] = value;
	var found = scores.get(key);
	return found != null ? found : -1;
}

function main():Int {
	var checks = [
		fromParameter(3) == 7,
		fromComparison(1),
		!fromComparison(2),
		fromLoop() == 12,
		fromField(new Item(9)) == 9,
		fromString(5) == "n5",
		fromAssignment() == 3,
		fromElement() == 7,
		fromClosure() == 2,
		fromCatch() == 4,
		fromUnshift() == 5,
		fromMap() == 20,
		fromMapAssignment("k", 8) == 8
	];
	for (index in 0...checks.length)
		if (!checks[index])
			return index + 1;
	return 42;
}
