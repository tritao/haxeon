struct Item {
	public var number:Int;
	public function new(number:Int) this.number = number;
}

class OptionalBox<T> {
	public var value:Null<T>;
	public function new(value:Null<T>) this.value = value;
	public function get():Null<T> return value;
}

function keep<T>(value:Null<T>):Null<T> return value;

function main():Int {
	var value:Null<Item> = new Item(42);
	var box = new OptionalBox<Null<Item>>(value);
	var result:Null<Item> = keep(box.get());
	return result == null ? 1 : result.number;
}
