// A local declared without what fixes its type takes it from the first use that does, as in Haxe: an empty array from
// what is pushed into it (even another empty array, or from inside a lambda) or the typed parameter it is passed to,
// `var x;` and `var x = null` from the value first assigned, wherever that is.
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

function main():Int
	return passedToTypedParameter() + assignedLater(true) + nestedEmptyArrays() + filledInLambda() == 19 ? 42 : 1;
