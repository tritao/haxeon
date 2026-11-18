// A switch used as a value must cover every value: an extractor's Int is covered only by `_` or a name.
class Main {
	static function main():Void {
		var values = [1, 2];
		var label = switch values {
			case _.length => 2: "two";
		};
		Sys.println(label);
	}
}
