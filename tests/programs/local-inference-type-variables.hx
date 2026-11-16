// A local declared without what fixes its type takes it from the first use that does, as in Haxe: an empty array from
// what is pushed into it (even another empty array, or from inside a lambda) or the typed parameter it is passed to,
// `var x;` and `var x = null` from the value first assigned, wherever that is, and `new Map()` from its first `set`.
class Box {
	public final label:String;

	public function new(label:String)
		this.label = label;
}

function fill(list:Array<Int>):Void
	for (i in 0...4)
		list.push(i);

function passedToTypedParameter():Int {
	var values = [];
	fill(values);
	var sum = 0;
	for (v in values)
		sum += v;
	return sum;
}

function make(label:String):Box
	return new Box(label);

function assignedLater(flag:Bool):Int {
	var box = null;
	var name;
	if (flag)
		name = "left";
	else
		name = "right";
	box = make(name);
	return box.label.length;
}

// `row` is fixed by its push, and `rows` by pushing `row` into it: one empty array's element is another's type.
function nestedEmptyArrays():Int {
	var rows = [];
	var row = [];
	row.push(3);
	rows.push(row);
	return rows[0][0];
}

function each(list:Array<Int>, f:Int->Void):Void
	for (v in list)
		f(v);

// The push that fixes `seen` is in a lambda the call types against `Int->Void`.
function filledInLambda():Int {
	var seen = [];
	each([1, 2, 3], v -> seen.push(v * 2));
	return seen[2];
}

function counts(words:Array<String>):Int {
	var seen = new Map();
	for (word in words)
		seen.set(word, (seen.get(word) ?? 0) + 1);
	return seen.get("a") ?? -1;
}

// The value is an array of a class, and the map is iterated once the `set` has fixed it.
function grouped():Int {
	var groups = new Map();
	groups.set(3, [new Box("a"), new Box("bc")]);
	var total = 0;
	for (boxes in groups)
		for (box in boxes)
			total += box.label.length;
	return total;
}

function main():Int
	return passedToTypedParameter() + assignedLater(true) + nestedEmptyArrays() + filledInLambda() + counts([
		"a",
		"b",
		"a"
	])
		+ grouped() == 24 ? 42 : 1;
