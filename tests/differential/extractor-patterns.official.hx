// Extractor patterns, as Haxe matches them: `expression => pattern`, with `_` the value. Cases that share an extractor's
// expression one after another evaluate it once; the cases before and after it match the value itself.
enum Token {
	Number(value:Int);
	Word(text:String);
}

class Main {
	static var calls = 0;

	static function split(x:Int):{a:Int, b:Int} {
		calls++;
		Sys.println("split " + x);
		return {a: x, b: x * 2};
	}

	static function parse(text:String):Null<Int>
		return Std.parseInt(text);

	static function token(text:String):Token {
		var number = Std.parseInt(text);
		return number == null ? Word(text) : Number(number);
	}

	static function main():Void {
		var described = switch 3 {
			case split(_) => {
				a:1, b:b
			}
			: "one " + b;
			case split(_) => {
				a:3, b:b
			}
			if (b > 100): "big";
			case split(_) => {
				a:3, b:b
			}
			: "three " + b;
			case _: "other";
		};
		Sys.println(described + " calls=" + calls);
		for (values in [[1, 2, 3], [4], []]) {
			switch values {
				case []:
					Sys.println("empty");
				case _.length => 3:
					Sys.println("three");
				case _.length => count:
					Sys.println("length " + count);
			}
		}
		for (text in ["12", "x", "7", "123"]) {
			var label = switch text {
				case "7": "seven";
				case parse(_) => null: "not a number";
				case whole = parse(_) => number if (whole.length > 2): "long " + number;
				case parse(_) => number: "short " + number;
			};
			Sys.println(label);
		}
		switch "abc" {
			case _.toUpperCase() => "ABC":
				Sys.println("upper");
			case _:
				Sys.println("other");
		}
		switch 5 {
			case _ * 2 => 10 | 20:
				Sys.println("ten or twenty");
			case _:
				Sys.println("no");
		}
		for (text in ["4", "four"]) {
			switch text {
				case token(_) => Number(value):
					Sys.println("number " + value);
				case token(_) => Word(word):
					Sys.println("word " + word);
			}
		}
		// A statement may leave the values of an Int extractor unmatched.
		var pair = [1, 2];
		switch pair {
			case _.length => 5:
				Sys.println("five");
		}
		Sys.println("done");
	}
}
