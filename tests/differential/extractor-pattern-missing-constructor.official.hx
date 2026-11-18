// An extractor whose value is an enum is covered constructor by constructor: Word is unmatched.
enum Token {
	Number(value:Int);
	Word(text:String);
}

class Main {
	static function token(text:String):Token
		return Number(1);

	static function main():Void {
		switch "4" {
			case token(_) => Number(value):
				Sys.println(value);
		}
	}
}
