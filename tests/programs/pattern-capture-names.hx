import modulevars.Settings.offset;

enum Payload {
	Some(value:Int);
	Empty;
}

enum abstract Kind(Int) {
	var X = 1;
	var Other = 2;
}

function count():Int
	return 90;

class Constants {
	static inline var X = 4;

	public static function matches(value:Int):Bool
		return switch value {
			case X: true;
			case _: false;
		};

	public static function matchesNested(value:Payload):Bool
		return switch value {
			case Some(X): true;
			case _: false;
		};
}

class Main {
	static var field = 80;

	static function matchesKind(value:Kind):Bool
		return switch value {
			case X: true;
			case _: false;
		};

	static function main():Void {
		var local = 70;
		var a = switch Some(10) {
			case Some(local): local;
			case _: 0;
		};
		var b = switch Some(11) {
			case Some(field): field;
			case _: 0;
		};
		var c = switch Some(12) {
			case Some(count) if (count == 12): count;
			case _: 0;
		};
		var d = 0;
		switch Some(9) {
			case Some(offset):
				d = offset;
			case _:
		}
		if (local != 70 || field != 80 || count() != 90 || offset() != 1)
			Sys.exit(1);
		if (!matchesKind(Kind.X) || matchesKind(Kind.Other) || !Constants.matches(4) || Constants.matches(5)
			|| !Constants.matchesNested(Some(4)) || Constants.matchesNested(Some(5)) || Constants.matchesNested(Empty))
			Sys.exit(2);
		Sys.exit(a + b + c + d);
	}
}
