// A static whose first argument does not accept the value is not its extension.
using Main.Tools;

class Tools {
	public static function length(values:Array<Int>):Int
		return values.length;
}

class Main {
	static function main():Void {
		Sys.println(3.length());
	}
}
