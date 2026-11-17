class Shape {
	public function new() {}

	public function name() return "shape";
}

class Circle extends Shape {
	public function new() {
		super();
	}

	override public function name() return "circle";
}

class Main {
	static function widen(flag:Bool) {
		if (flag)
			return 1.5;
		return 2;
	}

	static function nullFirst(flag:Bool) {
		if (flag)
			return null;
		return 7;
	}

	static function valueOnly(n:Int) {
		if (n > 0)
			return n * 2;
		return -n;
	}

	static function noValue(log:Array<String>) {
		log.push("ran");
		if (log.length > 5)
			return;
		log.push("again");
	}

	static function onlyThrows(message:String) {
		throw message;
	}

	static function shape(round:Bool) {
		if (round)
			return new Circle();
		return new Circle();
	}

	static function main() {
		var w:Float = widen(false);
		Sys.println(w + widen(true));
		var n = nullFirst(true);
		Sys.println(n == null ? "null" : "value");
		var m:Null<Int> = nullFirst(false);
		Sys.println(m);
		Sys.println(valueOnly(3) + valueOnly(-4));
		var log = [];
		noValue(log);
		Sys.println(log.join(","));
		try
			onlyThrows("stop")
		catch (error:String)
			Sys.println("caught " + error);
		Sys.println(shape(true).name());
	}
}
