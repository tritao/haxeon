// Static variables and finals of an abstract, read and written through it and from its methods, and initialized in Haxe's
// order: its statics go where the abstract is declared among the module's classes, and before a class whose initializers reach
// them (Before reads Counter.start, First calls Rate.make).
class Log {
	public static var lines:Array<String> = [];

	public static function add(line:String):Int {
		lines.push(line);
		return lines.length;
	}
}

class Before {
	public static var value:Int = Log.add("Before");
	public static var reads:Int = Counter.start;
}

abstract Counter(Int) from Int to Int {
	public static var start:Int = Log.add("Counter.start");
	public static final step:Int = 2;
	static var hidden:Int = 40;
	public static var made:Int = 0;
	public static inline var LIMIT:Int = 99;

	public function new(value:Int) {
		made++;
		this = value;
	}

	public function next():Counter
		return this + step;

	public static function total():Int
		return hidden + made;
}

class After {
	public static var value:Int = Log.add("After");
	public static var counter:Counter = new Counter(5);
}

class First {
	public static var value:Int = Rate.make();
}

abstract Rate(Int) from Int {
	public static var base:Int = Log.add("Rate.base") * 10;

	public static function make():Int
		return base + 1;
}

abstract Box<T>(Array<T>) from Array<T> {
	public static var count:Int = 0;

	public function add(value:T):Void {
		count++;
		this.push(value);
	}
}

class Main {
	static function main() {
		Sys.println(Log.lines.join(","));
		Sys.println(Before.reads);
		Sys.println(Counter.start + " " + Counter.step + " " + Counter.LIMIT);
		var c = new Counter(1);
		Sys.println((c.next():Int));
		Counter.made += 10;
		Counter.start = 7;
		Sys.println(Counter.total() + " " + Counter.start);
		Sys.println((After.counter:Int));
		Sys.println(First.value);
		var numbers:Box<Int> = [];
		numbers.add(1);
		var names:Box<String> = [];
		names.add("x");
		Sys.println(Box.count);
	}
}
