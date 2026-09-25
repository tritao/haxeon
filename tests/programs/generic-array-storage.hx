typedef Row = {var name:String; var size:Float;};

class Holder<T> {
	public final values:Array<T>;

	public function new(values:Array<T>)
		this.values = values;

	public function add(value:T):Int
		return values.push(value);

	public function at(index:Int):T
		return values[index];

	public function replace(index:Int, value:T):Void
		values[index] = value;

	public function find(value:T):Int
		return values.indexOf(value);

	public function drop(value:T):Bool
		return values.remove(value);

	public function last():T
		return values.pop();

	public function copied():Array<T>
		return [for (value in values) value];
}

function fails(action:() -> Void, fragment:String):Bool {
	try
		action()
	catch (error:Dynamic)
		return Std.string(error).indexOf(fragment) >= 0;
	return false;
}

function main():Int {
	// Reference elements share storage with erased generic code in both directions.
	var rows:Array<Row> = [{name: "a", size: 1.0}];
	var rowHolder = new Holder(rows);
	rowHolder.add({name: "b", size: 2.0});
	if (rows.length != 2 || rows[1].name != "b" || rowHolder.at(0).size != 1.0)
		return 1;
	var rowCopy:Array<Row> = rowHolder.copied();
	if (rowCopy.length != 2 || rowCopy[1].size != 2.0)
		return 2;
	rowCopy.push({name: "c", size: 3.0});
	if (rows.length != 2)
		return 3;

	// Primitive and String storage is viewed through the erased parameter without copying.
	var ints = [3, 4];
	var intHolder = new Holder(ints);
	intHolder.add(5);
	intHolder.replace(0, 30);
	if (ints.length != 3 || ints[0] != 30 || ints[2] != 5 || intHolder.find(4) != 1 || intHolder.last() != 5 || ints.length != 2)
		return 4;
	var floats = [0.5];
	new Holder(floats).add(1.5);
	if (floats.length != 2 || floats[1] != 1.5)
		return 5;
	var strings = ["x", "y"];
	var stringHolder = new Holder(strings);
	stringHolder.add("z");
	if (strings.join(",") != "x,y,z" || stringHolder.find("y") != 1 || !stringHolder.drop("x") || strings.join(",") != "y,z")
		return 6;
	var flags = [true];
	new Holder(flags).add(false);
	if (flags.length != 2 || flags[1])
		return 7;

	// Array<Dynamic> is a checked view over any storage.
	var dynamicInts:Array<Dynamic> = cast ints;
	dynamicInts.push(9);
	if (ints[2] != 9 || dynamicInts[0] != 30)
		return 8;
	if (!fails(() -> dynamicInts.push("text"), "") || ints.length != 3)
		return 9;

	// Dynamic storage takes its element type on the first concrete view and stays aliased.
	var boxed:Array<Dynamic> = [1, 2];
	var reinterpreted:Array<Int> = cast boxed;
	reinterpreted.push(3);
	if (boxed.length != 3 || boxed[2] != 3 || reinterpreted[0] + reinterpreted[1] != 3)
		return 10;
	var fromGeneric:Array<Int> = new Holder([1]).copied();
	fromGeneric.push(2);
	if (fromGeneric.length != 2 || fromGeneric[1] != 2)
		return 11;
	// A rejected element fails the view and leaves the dynamic array unchanged.
	var mixed:Array<Dynamic> = [1, "two"];
	if (!fails(() -> {
		var ints:Array<Int> = cast mixed;
		ints.push(3);
	}, "element 1 is String") || mixed.length != 2 || mixed[1] != "two")
		return 12;
	var truncated:Array<Dynamic> = [1.5];
	if (!fails(() -> {
		var ints:Array<Int> = cast truncated;
		ints.push(3);
	}, "Array element type mismatch"))
		return 13;
	var generalRows:Array<Row> = new Holder(rows).copied();
	if (generalRows[1].name != "b")
		return 14;

	// Nested reference arrays and erased reads keep their element types.
	var nested:Array<Array<Row>> = [rows];
	var nestedHolder = new Holder(nested);
	if (nestedHolder.at(0)[1].name != "b")
		return 15;
	var dynamicRows:Array<Dynamic> = cast rows;
	var viewed:Array<Row> = cast dynamicRows;
	if (viewed[0].name != "a")
		return 16;
	// Nested dynamic arrays are retyped when read through a concrete element view.
	var grid:Array<Dynamic> = [[1, 2]];
	var typedGrid:Array<Array<Int>> = cast grid;
	if (typedGrid[0][1] != 2)
		return 17;
	return 42;
}
