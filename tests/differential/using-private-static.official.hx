// A private static is not an extension outside its class: Haxe passes over it, and the String has no such field.
using Main.Tools;

class Tools {
	static function hidden(s:String):String
		return "hidden";
}

class Main {
	static function main():Void {
		Sys.println("x".hidden());
	}
}
