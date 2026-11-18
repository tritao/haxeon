// A rest parameter's arguments have its element type.
class Main {
	static function count(...values:Int):Int
		return values.length;

	static function main():Void {
		Sys.println(count(1, "two"));
	}
}
