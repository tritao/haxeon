// A spread passes rest arguments only.
class Main {
	static function twice(value:Int):Int
		return value * 2;

	static function main():Void {
		var numbers = [1];
		Sys.println(twice(...numbers));
	}
}
