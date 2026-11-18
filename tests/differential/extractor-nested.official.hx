// Extractors nested in a pattern: in an enum argument, a tuple or array element, a structure field and a `.match` pattern.
// Consecutive cases that differ only in the extractor's pattern evaluate it once; one whose pattern cannot fail covers what
// its outer pattern covers.
enum Maybe<T> {
	Some(value:T);
	None;
}

class Main {
	static var calls = 0;

	static function length(text:String):Int {
		calls++;
		return text.length;
	}

	static function describe(value:Maybe<String>):String {
		return switch value {
			case Some(length(_) => 3): "three";
			case Some(text = length(_) => 4): "four " + text;
			case Some(_.charAt(0) => "x"): "x word";
			case Some(_): "some";
			case None: "none";
		};
	}

	static function size(value:Maybe<String>):Int {
		return switch value {
			case Some(_.length => n): n;
			case None: -1;
		};
	}

	static function main():Void {
		for (value in [Some("abc"), Some("abcd"), Some("xy"), Some("hello"), None])
			Sys.println(describe(value));
		Sys.println("calls " + calls);
		Sys.println(size(Some("four")) + " " + size(None));
		Sys.println(Some("ab").match(Some(_.length => 2)) + " " + Some("abc").match(Some(_.length => 2) | None));
		var tuple = switch [1, "ab"] {
			case [_ * 2 => 2, _.length => 2]: "both";
			case [_ * 2 => 2, _]: "first";
			case _: "none";
		};
		Sys.println(tuple);
		var person = {name: "bob", age: 3};
		Sys.println(switch person {
			case {
				name:_.length => 3, age:age
			}
			: "three letters, " + age;
			case _: "other";
		});
		Sys.println(switch [Some("ab")] {
			case [Some(_.toUpperCase() => "AB")]: "upper";
			case _: "no";
		});
		switch Some("q") {
			case Some(_.length => 1):
				Sys.println("statement one");
			case _:
				Sys.println("statement other");
		}
		switch Some([1, 2, 3]) {
			case Some(_.length => 2 | 3) if (calls > 0):
				Sys.println("two or three");
			case Some(_):
				Sys.println("another length");
			case None:
		}
	}
}
