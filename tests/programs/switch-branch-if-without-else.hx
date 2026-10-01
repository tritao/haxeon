// A switch used as a value whose case ends in an `if` without `else`: the case is Void, and the next case parses.
enum Value {
	Flag(on:Bool);
	Other;
}

class Main {
	static var hits = 0;

	static function touch():Void
		hits++;

	static function main() {
		var apply = function(value:Value) switch (value) {
			case Flag(keep):
				if (!keep)
					touch();
			default:
				throw "boolean";
		};
		apply(Flag(false));
		apply(Flag(true));
		Sys.exit(hits == 1 ? 42 : 1);
	}
}
