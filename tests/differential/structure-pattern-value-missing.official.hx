// A switch used as a value must cover every structure: one whose count is not 1 is unmatched.
class Main {
	static function main():Void {
		var item = {count: 1};
		var label = switch item {
			case {
				count:1
			}
			: "one";
		};
		Sys.println(label);
	}
}
