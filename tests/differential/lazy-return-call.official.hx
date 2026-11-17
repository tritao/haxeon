import haxe.ds.Option;

enum Ins {
	Move(n:Int);
	Stop;
}

class Source {
	public static function base() return 40;

	public static function next() return base() + 1;
}

function label() return "module";

class Main {
	static var start = make();
	static var answer = Source.next() + 1;
	static var text = label() + "!";

	static function make() return Some(Move(2));

	static function steps() return [Move(1), Stop];

	static function main() {
		switch start {
			case Some(Move(n)): Sys.println(n);
			case _: Sys.println("other");
		}
		Sys.println(answer);
		Sys.println(text);
		Sys.println(steps().length);
	}
}
