// Type.enumConstructor, Type.enumParameters and Haxe's global EnumValueTools extensions on enum values, and where those
// extensions come in the order Haxe tries extensions: after the value's own @:using and its module's `using`.
using Main.Tools;
using haxe.EnumTools;

import haxe.EnumTools.EnumValueTools;

enum Color {
	Red;
	Green;
	Rgb(r:Int, g:Int, b:Int);
	Named(name:String, ?alpha:Float);
}

@:using(Main.ShapeTools)
enum Shape {
	Circle(radius:Float);
	Square;
}

enum Tree<T> {
	Leaf(value:T);
	Node(left:Tree<T>, right:Tree<T>);
}

class Tools {
	public static function getIndex(color:Color):Int
		return 42;
}

class ShapeTools {
	public static function getName(shape:Shape):String
		return "shape";
}

class Main {
	static function describe<T>(tree:Tree<T>):String
		return Type.enumConstructor(tree) + " " + Type.enumParameters(tree);

	static function main() {
		var color = Rgb(1, 2, 3);
		Sys.println(Type.enumConstructor(color));
		Sys.println(Type.enumParameters(color));
		Sys.println(Type.enumParameters(Red));
		Sys.println(Type.enumConstructor(Named("x")));
		Sys.println(Type.enumParameters(Named("x")));
		Sys.println(Type.enumParameters(Named("x", 0.5)));
		var tree:Tree<String> = Node(Leaf("a"), Leaf("b"));
		Sys.println(Type.enumParameters(tree));
		Sys.println(describe(tree));
		Sys.println(describe(Leaf(1.5)));
		var parameters = Type.enumParameters(color);
		parameters[0] = 99;
		Sys.println(color);
		Sys.println(color.getName());
		Sys.println(color.getParameters());
		Sys.println(color.equals(Rgb(1, 2, 3)));
		Sys.println(color.equals(Rgb(1, 2, 4)));
		// The enum's own @:using comes first; then the module's `using`, the last first: `using haxe.EnumTools` puts Haxe's
		// getIndex before `Main.Tools`'s.
		Sys.println(Green.getIndex());
		Sys.println(Circle(1).getName());
		Sys.println(Circle(1).getParameters());
		Sys.println(Square.getIndex());
		var nullable:Null<Color> = Rgb(1, 2, 3);
		Sys.println(nullable.getName());
		var name = color.getName;
		Sys.println(name());
		var same = Red.equals;
		Sys.println(same(Red) + " " + same(Green));
		Sys.println(EnumValueTools.getName(Green));
		Sys.println(haxe.EnumTools.EnumValueTools.getParameters(Rgb(4, 5, 6)));
		Sys.println(EnumValueTools.getIndex(color));
		Sys.println(EnumValueTools.equals(Red, Red));
	}
}
