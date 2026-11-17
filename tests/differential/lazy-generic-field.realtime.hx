class Bag<T> {
	public var items = new Array<T>();
	public var count = 0;

	public function new() {}

	public function add(item:T):Void {
		items.push(item);
		count++;
	}
}

class Main {
	static function main() {
		var ints = new Bag<Int>();
		ints.add(3);
		ints.add(4);
		var first:Int = ints.items[0];
		var strings = new Bag<String>();
		strings.add("x");
		var text:String = strings.items[0];
		Sys.println(first + ints.items[1]);
		Sys.println(text + strings.count);
		Sys.println(ints.count);
	}
}
