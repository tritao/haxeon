// A Dynamic value's index is an Int, as Haxe requires: a String key is an error.
class Main {
	static function main():Void {
		var value:Dynamic = ["k" => 1];
		Sys.println(value["k"]);
	}
}
