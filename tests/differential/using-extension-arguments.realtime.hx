// An extension call is checked as the static call it is: one argument too many.
using Main.Tools;

class Tools {
	public static function add(x:Int, y:Int):Int
		return x + y;
}

class Main {
	static function main():Void {
		Sys.println(1.add(2, 3));
	}
}
