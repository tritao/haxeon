// Array.indexOf, contains and remove on an array of enum values find a value equal to the one given, as == does for enums.
enum Color {
	Red;
	Green;
	Blue;
}

enum Shape {
	Dot;
	Circle(r:Int);
	Pair(a:Int, b:Int);
}

enum abstract Level(Int) {
	var Low = 1;
	var High = 2;
}

function check(name:String, ok:Bool, results:Array<String>):Void {
	if (!ok)
		results.push(name);
}

function main():Int {
	var failed:Array<String> = [];
	var colors = [Red, Green];
	check("contains present literal", colors.contains(Green), failed);
	check("contains absent", !colors.contains(Blue), failed);
	var wanted = Green;
	check("contains present variable", colors.contains(wanted), failed);
	var all:Array<Color> = [Red, Green, Blue];
	check("contains in typed array", all.contains(Blue), failed);
	check("indexOf", all.indexOf(Blue) == 2, failed);
	check("indexOf absent", colors.indexOf(Blue) == -1, failed);
	var fromParam = function(c:Color) return all.contains(c);
	check("contains via parameter", fromParam(Red) && fromParam(Green) && fromParam(Blue), failed);
	var built:Array<Color> = [];
	built.push(Blue);
	check("contains after push", built.contains(Blue), failed);
	var copy = all.copy();
	check("contains in copy", copy.contains(Green), failed);
	var shapes = [Dot, Circle(1), Pair(1, 2)];
	check("payload-less in mixed", shapes.contains(Dot), failed);
	check("payload constructor by its index", shapes.indexOf(Dot) == 0, failed);
	var levels = [Low, High];
	var unknownLevel:Level = cast 3;
	check("enum abstract contains", levels.contains(High) && !levels.contains(unknownLevel), failed);
	var nullable:Array<Null<Color>> = [Red, null];
	check("nullable array contains", nullable.contains(Red), failed);
	check("remove", all.remove(Green) && !all.contains(Green) && all.contains(Red), failed);
	var filtered = [for (c in [Red, Green, Blue]) if (c != Green) c];
	check("contains in comprehension result", filtered.contains(Blue) && !filtered.contains(Green), failed);
	return failed.length == 0 ? 42 : failed.length;
}
