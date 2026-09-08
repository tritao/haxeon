class Box {
	public var value:Int;

	public function new(value:Int) {
		this.value = value;
	}
}

class Holder {
	public var box:Box;

	public function new(box:Box) {
		this.box = box;
	}
}

class Main {
	static var events:String = "";
	static var values:Array<Int> = [10];
	static var box:Box = new Box(10);

	static function array():Array<Int> {
		events += "A";
		return values;
	}

	static function index():Int {
		events += "I";
		return 0;
	}

	static function rhs():Int {
		events += "R";
		values[0] = 100;
		return 2;
	}

	static function receiver():Box {
		events += "B";
		return box;
	}

	static function fieldRhs():Int {
		events += "F";
		box.value = 100;
		return 2;
	}

	static function fail():Int {
		events += "X";
		throw "stop";
	}

	static function swap(holder:Holder):Int {
		events += "S";
		holder.box = new Box(90);
		return 2;
	}

	static function main():Void {
		array()[index()] += rhs();
		Sys.println("array:" + events + ":" + values[0]);
		events = "";
		receiver().value += fieldRhs();
		Sys.println("field:" + events + ":" + box.value);
		events = "";
		var original = new Box(10);
		var holder = new Holder(original);
		holder.box.value += swap(holder);
		Sys.println("dotted:" + events + ":" + original.value + ":" + holder.box.value);
		events = "";
		values[0] = 10;
		try {
			array()[index()] += fail();
		} catch (error:String) {}
		Sys.println("throw-rhs:" + events + ":" + values[0]);
		events = "";
		try {
			array()[fail()] += rhs();
		} catch (error:String) {}
		Sys.println("throw-index:" + events + ":" + values[0]);
		events = "";
		var flag = true;
		var old = array()[flag ? index() : fail()]++;
		Sys.println("postfix:" + events + ":" + old + ":" + values[0]);
		events = "";
		array()[flag ? index() : fail()] += flag ? rhs() : fail();
		Sys.println("conditional:" + events + ":" + values[0]);
	}
}
