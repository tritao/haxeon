// A local declared without what fixes its type takes it from the first use that does, as in Haxe: an empty array from
// what is pushed into it (even another empty array, or from inside a lambda) or the typed parameter it is passed to,
// `var x;` and `var x = null` from the value first assigned, wherever that is, and `new Map()` from its first `set`.
// What a later use expects (a return, a typed argument) is the context values flowing in are typed in, not the type.
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

typedef Argument = {name:String, ?optional:Bool};

function count(arguments:Array<Argument>):Int
	return arguments.length;

// The object pushed is typed as the structure `count` expects, optional field and all, so the array is one of those.
function hintedStructure():Int {
	var arguments = [];
	arguments.push({name: "a"});
	return count(arguments);
}

// The literal pushed is typed as the Float the return expects, so the array is one of Floats.
function hintedNumbers():Array<Float> {
	var values = [];
	values.push(1);
	return values;
}

// `indexOf` and `contains` before any push fix the element from the value compared, as Haxe unifies the two.
function comparedFirst(list:String):Int {
	var sources = [];
	for (source in list.split(","))
		if (sources.indexOf(source) < 0)
			sources.push(source);
	var seen = [];
	var had = seen.contains(3);
	seen.push(3);
	return had ? 0 : sources.length;
}

typedef ToolRequest = {main:String, classPaths:Array<String>, defines:Array<String>};

// The arrays are fixed by the nullable values `shift` returns, read as the Strings the returned structure expects: an
// object literal returned as a `Null<ToolRequest>` is a present one, whose fields are the structure's.
function toolRequest(arguments:Array<String>):Null<ToolRequest> {
	var classPaths = [], defines = [];
	while (arguments.length > 0) {
		var argument = arguments.shift();
		switch argument {
			case "--cp" | "--define":
				(argument == "--cp" ? classPaths : defines).push(arguments.shift());
			case _:
				return {main: argument, classPaths: classPaths, defines: defines};
		}
	}
	return null;
}

function nullableIntoHinted():Int {
	var request = toolRequest(["--cp", "src", "--define", "x", "Main"]);
	return request == null ? 0 : request.classPaths.length + request.defines.length;
}

function main():Int
	return passedToTypedParameter() + assignedLater(true) + nestedEmptyArrays() + filledInLambda() + counts([
		"a",
		"b",
		"a"
	])
		+ grouped() + hintedStructure() + Std.int(hintedNumbers()[0]) + comparedFirst("a,b,a") + nullableIntoHinted()
		== 30 ? 42 : 1;
