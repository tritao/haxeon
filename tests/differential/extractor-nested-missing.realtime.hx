// A nested extractor's pattern can fail, so its case does not cover its constructor: `Some(_)` is unmatched.
enum Maybe<T> {
	Some(value:T);
	None;
}

class Main {
	static function main():Void {
		var value = Some("abc");
		var label = switch value {
			case Some(_.length => 3): "three";
			case None: "none";
		};
		Sys.println(label);
	}
}
