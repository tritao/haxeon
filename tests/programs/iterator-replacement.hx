// Local array iterators become an array and a position; aliasing, reassignment, resuming and live array changes must behave as before.
// Expected values come from stock Haxe/HL.
class Item {
	public var weight:Int;

	public function new(weight:Int) {
		this.weight = weight;
	}
}

function sumInts(values:Array<Int>):Int {
	var total = 0;
	var iterator = values.iterator();
	while (iterator.hasNext())
		total += iterator.next();
	return total;
}

function growWhileIterating(values:Array<Int>):Int {
	var total = 0, steps = 0;
	var iterator = values.iterator();
	while (iterator.hasNext()) {
		var value = iterator.next();
		total += value;
		steps++;
		if (steps < 4)
			values.push(value * 10);
	}
	return total * 100 + steps;
}

function shrinkWhileIterating(values:Array<Int>):Int {
	var total = 0;
	var iterator = values.iterator();
	while (iterator.hasNext()) {
		total += iterator.next();
		values.pop();
	}
	return total * 100 + values.length;
}

function sharedIterator(values:Array<Int>):Int {
	var first = values.iterator();
	var second = first;
	var total = 0;
	while (first.hasNext()) {
		total += first.next();
		if (second.hasNext())
			total += second.next() * 100;
	}
	return total;
}

function resumeAfterBreak(values:Array<Int>):Int {
	var iterator = values.iterator();
	var head = 0, tail = 0;
	while (iterator.hasNext()) {
		var value = iterator.next();
		if (value > 3)
			break;
		head += value;
	}
	while (iterator.hasNext())
		tail += iterator.next();
	return head * 1000 + tail;
}

function reassigned(left:Array<Int>, right:Array<Int>):Int {
	var iterator = left.iterator();
	var total = 0;
	while (iterator.hasNext())
		total += iterator.next();
	iterator = right.iterator();
	while (iterator.hasNext())
		total += iterator.next() * 2;
	return total;
}

function nestedPairs(values:Array<Int>):Int {
	var total = 0;
	var outer = values.iterator();
	while (outer.hasNext()) {
		var a = outer.next();
		var inner = values.iterator();
		while (inner.hasNext()) {
			var b = inner.next();
			if (a < b)
				total += a * b;
		}
	}
	return total;
}

function overStrings(words:Array<String>):String {
	var joined = "";
	var iterator = words.iterator();
	while (iterator.hasNext()) {
		var word = iterator.next();
		joined += word.length > 1 ? word.charAt(0) + word.charAt(1) : word;
	}
	return joined;
}

function overObjects(items:Array<Item>):Int {
	var total = 0;
	var iterator = items.iterator();
	while (iterator.hasNext())
		total += iterator.next().weight;
	return total;
}

function overBooleans(flags:Array<Bool>):Int {
	var count = 0, index = 1;
	var iterator = flags.iterator();
	while (iterator.hasNext()) {
		if (iterator.next())
			count += index;
		index *= 2;
	}
	return count;
}

function overFloats(values:Array<Float>):Float {
	var total = 0.0;
	var iterator = values.iterator();
	while (iterator.hasNext())
		total += iterator.next() * 0.5;
	return total;
}

function insideTry(values:Array<Int>, limit:Int):Int {
	var total = 0, caught = 0;
	var iterator = values.iterator();
	while (iterator.hasNext()) {
		try {
			var value = iterator.next();
			if (value > limit)
				throw "too big";
			total += value;
		} catch (error:Dynamic) {
			caught++;
		}
	}
	return total * 10 + caught;
}

function inLoopBody(rows:Array<Array<Int>>):Int {
	var total = 0;
	for (row in rows) {
		var iterator = row.iterator();
		var rowTotal = 0;
		while (iterator.hasNext())
			rowTotal += iterator.next();
		total = total * 7 + rowTotal;
	}
	return total;
}

function main():Int {
	var empty:Array<Int> = [];
	var r:Array<Dynamic> = [
		sumInts([3, 4, 5, 6]),
		sumInts(empty),
		growWhileIterating([1, 2, 3]),
		shrinkWhileIterating([5, 6, 7, 8, 9]),
		sharedIterator([1, 2, 3, 4, 5, 6]),
		resumeAfterBreak([1, 2, 9, 4, 5]),
		reassigned([1, 2], [10, 20, 30]),
		nestedPairs([1, 2, 3, 4]),
		overStrings(["ab", "c", "def"]),
		overObjects([new Item(3), new Item(4), new Item(5)]),
		overBooleans([true, false, true, true]),
		overFloats([1.5, 2.5, 4.0]),
		insideTry([1, 50, 3, 60, 5], 10),
		inLoopBody([[1, 2], [3], [], [4, 5, 6]])
	];
	var expected = [
		"18", "0", "6606", "1802", "1209", "3009", "123", "35", "abcde", "12", "13", "4", "92", "1191"
	];
	for (index in 0...expected.length)
		if (Std.string(r[index]) != expected[index])
			return index + 1;
	return 42;
}
