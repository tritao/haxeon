struct Pair {
	public var value:Int;
	public function new(value:Int) this.value = value;
}

// Merely describing a lane array must not bind its unreachable runtime operations.
enum Value {
	Item(value:Pair);
	Items(values:Array<Pair>);
}

function main():Int {
	var value:Value = Item(new Pair(42));
	var values:Array<Dynamic> = [19, 23], total = 0;
	for (entry in values.iterator()) total += (cast entry:Int);
	if (total != 42) return 1;
	var copy = values.slice(0, 1).concat([23]);
	copy.reverse();
	if ((cast copy.pop():Int) != 19 || (cast copy.shift():Int) != 23) return 2;
	copy.insert(0, 42);
	copy[0] = 41;
	copy.push(1);
	if ((cast copy.splice(1, 1)[0]:Int) != 1) return 3;
	copy.unshift(1);
	var removed = copy.splice(0, 1);
	if ((cast removed[0]:Int) != 1) return 4;
	copy.resize(3);
	if (copy[1] != null || copy[2] != null) return 5;
	copy.resize(1);
	copy[2] = 1;
	if (copy.splice(1, 1)[0] != null) return 6;
	if ((cast copy.pop():Int) + (cast copy.shift():Int) != 42 || copy.length != 0) return 7;
	return switch value { case Item(pair): pair.value; default: 0; };
}
