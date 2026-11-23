// A generic class holding a map of its parameter, at a parameter that is itself a map: the table of tables a compiler keeps by
// owner, read through a generic function at each value type. The inner maps are runtime handles the outer map stores as they
// are, so the class is specialized for them rather than shared with a map of Dynamic values.
typedef Info = {
	final owner:String;
	final isStatic:Bool;
}

class Box {
	public final size:Int;

	public function new(size:Int)
		this.size = size;
}

class Table<T> {
	final entries:Map<String, T>;
	public var reads:Null<Array<String>> = null;

	public function new(?over:Map<String, T>)
		entries = over == null ? [] : over;

	public function get(name:String):T {
		var recorder = reads;
		if (recorder != null)
			recorder.push(name);
		return cast entries.get(name);
	}

	public function exists(name:String):Bool
		return entries.exists(name);
}

function member<V>(table:Table<Map<String, V>>, owner:String, name:String):Null<V> {
	var members = table.get(owner);
	return members == null ? null : members.get(name);
}

function main():Int {
	var failures:Array<String> = [];
	var info:Info = {owner: "A", isStatic: true};
	var infos = new Table(["A" => ["f" => info]]);
	var reads:Array<String> = [];
	infos.reads = reads;
	var found = member(infos, "A", "f");
	if (found == null || found.owner != "A" || !found.isStatic)
		failures.push("structure values");
	if (member(infos, "B", "f") != null || member(infos, "A", "g") != null || reads.length != 3)
		failures.push("missing entries");
	var names = new Table(["A" => ["f" => "sig"]]);
	if (member(names, "A", "f") != "sig" || !names.exists("A"))
		failures.push("string values");
	var boxes = new Table(["A" => ["f" => new Box(4)]]);
	var box = member(boxes, "A", "f");
	if (box == null || box.size != 4)
		failures.push("class values");
	var direct = new Table(["A" => ["f" => 1.5]]).get("A");
	if (direct.get("f") != 1.5)
		failures.push("direct read");
	// A literal's structure as the type argument.
	var literal = new Table(["A" => ["f" => {
		owner:"L"
	}]]);
	var made = member(literal, "A", "f");
	if (made == null || made.owner != "L")
		failures.push("literal structures");
	return failures.length == 0 ? 42 : failures.length;
}
