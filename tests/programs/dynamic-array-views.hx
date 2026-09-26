class Box<T> {
	public final values:Array<T>;

	public function new(values:Array<T>)
		this.values = values;

	public function first():T
		return values.shift();

	public function put(index:Int, value:T):Void
		values[index] = value;

	public function insert(index:Int, value:T):Void
		values.insert(index, value);

	public function unshift(value:T):Int
		return values.unshift(value);

	public function slice(start:Int, end:Int):Array<T>
		return values.slice(start, end);

	public function splice(start:Int, length:Int):Array<T>
		return values.splice(start, length);

	public function concat(other:Array<T>):Array<T>
		return values.concat(other);

	public function copy():Array<T>
		return values.copy();

	public function reverse():Void
		values.reverse();

	public function resize(length:Int):Void
		values.resize(length);
}

function fails(action:() -> Void, fragment:String):Bool {
	try
		action()
	catch (error:Dynamic)
		return Std.string(error).indexOf(fragment) >= 0;
	return false;
}

function main():Int {
	// Float storage keeps eight-byte slots through the erased parameter.
	var floats = [0.5, 1.5];
	var floatBox = new Box(floats);
	floatBox.put(3, 2.5);
	if (floats.length != 4 || floats[2] != 0.0 || floats[3] != 2.5)
		return 1;
	if (floatBox.first() != 0.5 || floats.length != 3 || floatBox.unshift(9.0) != 4 || floats[0] != 9.0)
		return 2;
	floatBox.insert(1, 7);
	if (floats[1] != 7.0 || floats.length != 5)
		return 3;

	// Storage operations keep the element type of the source storage.
	var ints = [1, 2, 3, 4, 5];
	var intBox = new Box(ints);
	var middle:Array<Int> = intBox.slice(1, 3);
	if (middle.length != 2 || middle[1] != 3)
		return 4;
	var removed:Array<Int> = intBox.splice(0, 2);
	if (removed[0] + removed[1] != 3 || ints.length != 3 || ints[0] != 3)
		return 5;
	intBox.reverse();
	var copied:Array<Int> = intBox.copy();
	copied.push(0);
	if (ints[0] != 5 || ints[2] != 3 || ints.length != 3 || copied.length != 4)
		return 6;
	var joined:Array<Int> = intBox.concat([6]);
	if (joined.length != 4 || joined[3] != 6)
		return 7;
	intBox.resize(1);
	if (ints.length != 1 || ints[0] != 5)
		return 8;

	var flags = [true, false];
	new Box(flags).put(0, false);
	if (flags[0] || flags.length != 2)
		return 9;
	var words = ["a", "b"];
	var wordBox = new Box(words);
	wordBox.put(2, "c");
	if (wordBox.first() != "a" || words.join("") != "bc")
		return 10;

	// Dynamic views: growth, search, removal and mixed concatenation.
	var grown = [1];
	var grownView:Array<Dynamic> = cast grown;
	grownView[3] = 4;
	if (grown.length != 4 || grown[1] != 0 || grown[3] != 4)
		return 11;
	var halves = [1.5, 2.5];
	var halvesView:Array<Dynamic> = cast halves;
	if (halvesView.indexOf(2.5) != 1 || halvesView.indexOf("2.5") != -1 || !halvesView.remove(1.5) || halves.length != 1 || halves[0] != 2.5)
		return 12;
	var other:Array<Dynamic> = ["x"];
	var mixed = grownView.concat(other);
	if (mixed.length != 5 || mixed[3] != 4 || mixed[4] != "x")
		return 13;
	if (halvesView.pop() != 2.5 || halves.length != 0)
		return 14;
	if (!fails(() -> halvesView.pop(), "Array.pop on an empty array"))
		return 15;
	if (!fails(() -> grownView[9], ""))
		return 16;

	// Dynamic storage retypes to Float, converting Int elements.
	var numbers:Array<Dynamic> = [1, 2.5];
	var asFloats:Array<Float> = cast numbers;
	if (asFloats[0] + asFloats[1] != 3.5 || numbers[0] != 1.0)
		return 17;
	asFloats.push(4);
	if (numbers.length != 3 || numbers[2] != 4.0)
		return 18;

	// Concrete storage never changes element type.
	var single = [1];
	var singleView:Array<Dynamic> = cast single;
	if (!fails(() -> {
		var strings:Array<String> = cast singleView;
		strings.push("a");
	}, "Array element type mismatch: Int -> String"))
		return 19;
	var parts:Array<Dynamic> = cast "a,b".split(",");
	if (parts[1] != "b" || !fails(() -> parts.push(3), ""))
		return 20;
	var bools:Array<Dynamic> = [true, 1];
	if (!fails(() -> {
		var flags:Array<Bool> = cast bools;
		flags.push(false);
	}, "element 1 is Int"))
		return 21;
	return 42;
}
