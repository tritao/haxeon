class Main {
	static function main():Void {
		var strings = ["b" => 2, "a" => 1];
		var nested:Map<Int, Map<String, Int>> = [4 => strings];
		var nullable:Map<String, Null<String>> = ["nil" => null, "yes" => "some text"];
		Sys.println(Std.string(strings));
		Sys.println(nested.toString());
		Sys.println(Std.string(nullable));
	}
}
