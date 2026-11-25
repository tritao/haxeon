// A value of a type parameter takes only the extensions its constraints accept.
using Main.Tools;

class Tools {
	public static function label(text:String):String
		return "label " + text;
}

interface Shape {
	function area():Int;
}

class Main {
	static function measure<T:Shape>(value:T):String return value.label();

	static function main():Void {}
}
