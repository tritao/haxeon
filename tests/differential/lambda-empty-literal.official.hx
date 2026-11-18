// An empty array literal passed straight to a generic function: its element type is fixed by nothing, so it is Dynamic, as
// in Haxe. A literal that meets a typed argument takes its element type from it (`Lambda.has([], 3)`).
class Main {
	static function main():Void {
		Sys.println(Lambda.empty([]) + " " + Lambda.count([]) + " " + Lambda.empty([1]));
		Sys.println(Lambda.has([], 3) + " " + Lambda.exists([], value -> value > 2));
	}
}
