// Array.sort is a stable merge sort: it agrees with a reference insertion sort for every length around its run and
// merge boundaries, keeps equal elements in order, sorts typed, value, record and string elements, propagates
// comparator exceptions, and calls the comparator O(n log n) times.

class Item {
	public final key:Int;
	public final index:Int;

	public function new(key:Int, index:Int) {
		this.key = key;
		this.index = index;
	}
}

@:value
class Pair {
	public final key:Int;
	public final index:Int;

	public function new(key:Int, index:Int) {
		this.key = key;
		this.index = index;
	}
}

class Random {
	var state:Int;

	public function new(seed:Int)
		state = seed;

	public function next(bound:Int):Int {
		state = (state * 75 + 74) % 65537;
		return state % bound;
	}
}

function referenceSort(values:Array<Int>):Array<Int> {
	var result = values.copy();
	for (index in 1...result.length) {
		var key = result[index], scan = index - 1;
		while (scan >= 0 && result[scan] > key) {
			result[scan + 1] = result[scan];
			scan--;
		}
		result[scan + 1] = key;
	}
	return result;
}

function sameInts(a:Array<Int>, b:Array<Int>):Bool {
	if (a.length != b.length)
		return false;
	for (index in 0...a.length)
		if (a[index] != b[index])
			return false;
	return true;
}

function randomInts(random:Random, length:Int, bound:Int):Array<Int> {
	var values = [];
	for (_ in 0...length)
		values.push(random.next(bound));
	return values;
}

function intsAgree(random:Random):Bool {
	for (length in 0...70) {
		for (bound in [3, 1000]) {
			var values = randomInts(random, length, bound),
				expected = referenceSort(values);
			values.sort((a, b) -> a - b);
			if (!sameInts(values, expected))
				return false;
		}
	}
	var values = randomInts(random, 777, 100000),
		expected = referenceSort(values);
	values.sort((a, b) -> a - b);
	return sameInts(values, expected);
}

function itemsStable(random:Random):Bool {
	for (length in [0, 1, 2, 7, 8, 9, 16, 17, 33, 100, 1000]) {
		var items = [for (index in 0...length) new Item(random.next(5), index)];
		items.sort((a, b) -> a.key - b.key);
		for (index in 1...items.length) {
			var previous = items[index - 1], current = items[index];
			if (previous.key > current.key || (previous.key == current.key && previous.index > current.index))
				return false;
		}
	}
	return true;
}

function valuesStable(random:Random):Bool {
	var pairs = [for (index in 0...300) new Pair(random.next(7), index)];
	pairs.sort((a, b) -> a.key - b.key);
	if (pairs.length != 300)
		return false;
	var seen = [for (_ in 0...300) false];
	for (index in 0...pairs.length) {
		var current = pairs[index];
		if (seen[current.index])
			return false;
		seen[current.index] = true;
		if (index > 0) {
			var previous = pairs[index - 1];
			if (previous.key > current.key || (previous.key == current.key && previous.index > current.index))
				return false;
		}
	}
	return true;
}

function recordsStable():Bool {
	var records = [for (index in 0...50) {key: (index * 7) % 4, index: index}];
	records.sort((a, b) -> a.key - b.key);
	for (index in 1...records.length) {
		var previous = records[index - 1], current = records[index];
		if (previous.key > current.key || (previous.key == current.key && previous.index > current.index))
			return false;
	}
	return true;
}

function stringsSort():Bool {
	var words = [
		"kilo",
		"alpha",
		"juliet",
		"echo",
		"bravo",
		"india",
		"hotel",
		"charlie",
		"golf",
		"delta",
		"foxtrot",
		"lima",
		"alpha"
	];
	words.sort(Reflect.compare);
	var byLength = ["ccc", "a", "bb", "dd", "e", "fff", "g", "hh", "iii", "j"];
	byLength.sort((a, b) -> a.length - b.length);
	return words.join(",") == "alpha,alpha,bravo,charlie,delta,echo,foxtrot,golf,hotel,india,juliet,kilo,lima"
		&& byLength.join(",") == "a,e,g,j,bb,dd,hh,ccc,fff,iii";
}

function floatsSort():Bool {
	var values = [for (index in 0...40) ((index * 13) % 40) * 0.5];
	values.sort((a, b) -> a < b ? -1 : a > b ? 1 : 0);
	for (index in 0...values.length)
		if (values[index] != index * 0.5)
			return false;
	return true;
}

function edgeShapes():Bool {
	var empty:Array<Int> = [];
	empty.sort((a, b) -> a - b);
	var one = [5];
	one.sort((a, b) -> a - b);
	var sorted = [for (index in 0...100) index];
	sorted.sort((a, b) -> a - b);
	var reversed = [for (index in 0...100) 99 - index];
	reversed.sort((a, b) -> a - b);
	var descending = [for (index in 0...100) index];
	descending.sort((a, b) -> b - a);
	var same = [for (_ in 0...50) 3];
	same.sort((a, b) -> a - b);
	for (index in 0...100)
		if (sorted[index] != index || reversed[index] != index || descending[index] != 99 - index)
			return false;
	return empty.length == 0 && one.length == 1 && one[0] == 5 && same.length == 50 && same[49] == 3;
}

function comparisons(values:Array<Int>):Int {
	var calls = 0;
	values.sort((a, b) -> {
		calls++;
		return a - b;
	});
	for (index in 1...values.length)
		if (values[index - 1] > values[index])
			return -1;
	return calls;
}

// n log2 n * 1.5 for n = 20000; insertion sort makes about 10^8 calls.
function complexityBounded(random:Random):Bool {
	var length = 20000, bound = 428000;
	var randomCalls = comparisons(randomInts(random, length, 1000000)),
		sortedCalls = comparisons([for (index in 0...length) index]),
		reversedCalls = comparisons([for (index in 0...length) length - index]),
		equalCalls = comparisons([for (_ in 0...length) 1]);
	return randomCalls > 0 && randomCalls <= bound && reversedCalls > 0 && reversedCalls <= bound && sortedCalls > 0 && sortedCalls < 2 * length
		&& equalCalls > 0 && equalCalls < 2 * length;
}

function exceptionPropagates():Bool {
	var values = [for (index in 0...50) 50 - index], calls = 0;
	try {
		values.sort((a, b) -> {
			calls++;
			if (calls == 30)
				throw "stop";
			return a - b;
		});
	} catch (error:String) {
		return error == "stop" && calls == 30 && values.length == 50;
	}
	return false;
}

function main():Int {
	var random = new Random(12345);
	var failures = 0;
	if (!intsAgree(random))
		failures |= 1;
	if (!itemsStable(random))
		failures |= 2;
	if (!valuesStable(random))
		failures |= 4;
	if (!recordsStable())
		failures |= 8;
	if (!stringsSort())
		failures |= 16;
	if (!floatsSort())
		failures |= 32;
	if (!edgeShapes())
		failures |= 64;
	if (!complexityBounded(random))
		failures |= 128;
	if (!exceptionPropagates())
		failures |= 256;
	// Wasm parity forbids host printing, so a failure is only the exit code; `failures` names the checks.
	return failures == 0 ? 42 : 1;
}
