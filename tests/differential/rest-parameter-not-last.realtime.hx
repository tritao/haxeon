// Only the last argument may be a rest parameter.
class Main {
	static function f(...values:Int, last:Int):Int
		return last;

	static function main():Void {
		Sys.println(f(1));
	}
}
