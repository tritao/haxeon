// A spread passes all the rest arguments: none may follow it.
class Main {
	static function count(...values:Int):Int
		return values.length;

	static function main():Void {
		var numbers = [1, 2];
		Sys.println(count(...numbers, 3));
	}
}
