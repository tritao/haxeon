// Haxe's Type.enumConstructor, Type.enumParameters and the global EnumValueTools extensions, on values of known enum types.
import haxe.EnumTools.EnumValueTools;

enum Color {
	Red;
	Green;
	Rgb(r:Int, g:Int, b:Int);
	Named(name:String, ?alpha:Float);
	Mixed(on:Bool, ratio:Float, inner:Color);
}

enum Tree<T> {
	Leaf(value:T);
	Node(left:Tree<T>, right:Tree<T>);
}

enum Single {
	Only(value:Float);
}

function describe<T>(tree:Tree<T>):String
	return Type.enumConstructor(tree) + ":" + Std.string(Type.enumParameters(tree));

function check(failures:Array<String>, label:String, actual:Dynamic, expected:String):Void {
	if (Std.string(actual) != expected)
		failures.push(label + ": " + Std.string(actual) + " != " + expected);
}

function main():Int {
	var failures:Array<String> = [];
	var color = Rgb(1, 2, 3);
	check(failures, "constructor", Type.enumConstructor(color), "Rgb");
	check(failures, "nullary constructor", Type.enumConstructor(Green), "Green");
	check(failures, "parameters", Type.enumParameters(color), "[1,2,3]");
	check(failures, "nullary parameters", Type.enumParameters(Red).length, "0");
	check(failures, "omitted optional", Type.enumParameters(Named("x")), "[x,null]");
	check(failures, "given optional", Type.enumParameters(Named("x", 0.5)), "[x,0.5]");
	check(failures, "mixed", Type.enumParameters(Mixed(true, 1.5, Rgb(4, 5, 6))), "[true,1.5,Rgb(4,5,6)]");
	check(failures, "single", Type.enumConstructor(Only(2.5)) + Type.enumParameters(Only(2.5)), "Only[2.5]");
	var tree:Tree<String> = Node(Leaf("a"), Leaf("b"));
	check(failures, "generic", Type.enumParameters(tree), "[Leaf(a),Leaf(b)]");
	check(failures, "generic function", describe(tree), "Node:[Leaf(a),Leaf(b)]");
	check(failures, "generic function leaf", describe(Leaf(7)), "Leaf:[7]");
	var copy = Type.enumParameters(color);
	copy[0] = 99;
	check(failures, "fresh array", color, "Rgb(1,2,3)");
	var calls = 0;
	function next():Color {
		calls++;
		return Rgb(calls, 0, 0);
	}
	check(failures, "evaluated once", Type.enumParameters(next()), "[1,0,0]");
	check(failures, "evaluated once count", calls, "1");
	// Haxe's EnumValueTools apply to every enum value, after the value's own and its module's extensions.
	check(failures, "getName", color.getName(), "Rgb");
	check(failures, "getParameters", color.getParameters(), "[1,2,3]");
	check(failures, "getIndex", Green.getIndex(), "1");
	check(failures, "equals", color.equals(Rgb(1, 2, 3)), "true");
	check(failures, "not equals", color.equals(Rgb(1, 2, 4)), "false");
	var nullable:Null<Color> = Named("y");
	check(failures, "nullable getName", nullable.getName(), "Named");
	var name = color.getName;
	check(failures, "bound getName", name(), "Rgb");
	var same = Red.equals;
	check(failures, "bound equals", same(Red) + " " + same(Green), "true false");
	check(failures, "qualified", EnumValueTools.getName(Green) + EnumValueTools.getParameters(color), "Green[1,2,3]");
	check(failures, "qualified index", EnumValueTools.getIndex(color), "2");
	check(failures, "qualified equals", EnumValueTools.equals(Red, Red), "true");
	// The Wasm parity corpus runs without a host printer: the exit code says how many checks failed.
	return failures.length == 0 ? 42 : failures.length;
}
