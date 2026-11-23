// A generic class whose members hold its type parameter inside a structure (`iterator():Iterator<T>`, `get():{value:T}`, a
// field `{value:T}`): read at a type argument, from a generic function or not, they give that argument's structure.
class Items<T> {
	final items:Array<T>;

	public function new(items:Array<T>)
		this.items = items;

	public function iterator():Iterator<T>
		return items.iterator();
}

class Box<T> {
	public var slot:{value:T};

	public function new(value:T)
		slot = {value: value};

	public function get():{value:T} return slot;

	public function entry(key:Int):{key:Int, value:T} return {key: key, value: slot.value};

	public function put(entry:{value:T}):Void
		slot = entry;
}

function count<T>(items:Items<T>):Int {
	var result = 0;
	for (_ in items)
		result++;
	return result;
}

function first<T>(box:Box<T>):T
	return box.get().value;

function main():Int {
	var failures:Array<String> = [];
	var names = new Items(["a", "bb"]), joined = "";
	for (name in names)
		joined += name;
	if (joined != "abb")
		failures.push("concrete loop");
	if (count(names) != 2 || count(new Items([1.5, 2.5, 3.5])) != 3 || count(new Items([true])) != 1)
		failures.push("generic loop");
	var iterator = new Items([4, 5]).iterator(), sum = 0;
	while (iterator.hasNext())
		sum += iterator.next();
	if (sum != 9)
		failures.push("iterator");
	var box = new Box("x");
	if (box.get().value != "x" || first(box) != "x" || first(new Box(7)) != 7)
		failures.push("structure result");
	var numbered = new Box(5).entry(3);
	if (numbered.key + numbered.value != 8 || box.entry(1).value != "x")
		failures.push("key-value entry");
	box.put({value: "y"});
	if (box.slot.value != "y")
		failures.push("structure argument and field");
	// The structure is the object the box holds, not a copy of it.
	box.get().value = "z";
	if (box.slot.value != "z")
		failures.push("structure identity");
	return failures.length == 0 ? 42 : failures.length;
}
