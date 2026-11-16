// A local's type comes from how it is first filled, as in Haxe: an empty array from a push through a conditional receiver,
// a push inside a lambda it passes on, an object literal's empty field from where the object is returned, and `var x;` from a first assignment that reads locals declared after it.
class Holder {
	public final items:Array<String>;

	public function new(items:Array<String>)
		this.items = items;
}

function split(arguments:Array<String>):Int {
	var flags = [], names = [], index = 0;
	while (index < arguments.length) {
		var argument = arguments[index++];
		(StringTools.startsWith(argument, "-") ? flags : names).push(argument);
	}
	return flags.length * 10 + names.length;
}

function first(values:Array<String>):Int {
	var holder;
	try {
		var copied = values.copy();
		holder = new Holder(copied);
	} catch (_:Dynamic) {
		return -1;
	}
	return holder.items.length;
}

function later(callback:() -> Void):Void
	callback();

function collect(values:Array<Int>):Int {
	var seen = [];
	for (value in values)
		later(() -> seen.push('v$value'));
	return seen.length == values.length && seen[0] == "v7" ? seen.length : -1;
}

function lane():{label:String, results:Array<Int>} {
	var made = {label: "lane", results: []};
	made.results.push(3);
	return made;
}

function main():Int
	return lane().results[0] == 3 && split(["-a", "b", "-c", "d", "e"]) == 23 && first(["x", "y"]) == 2 && collect([
		7,
		8
	]) == 2 ? 42 : 1;
