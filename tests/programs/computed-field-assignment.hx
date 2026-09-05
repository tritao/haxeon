class Box {
	public var value:Int = 0;
}

class Store {
	public static var box:Box = new Box();

	public static function get():Box {
		return box;
	}
}

function main():Int {
	Store.get().value = 42;
	return Store.box.value;
}
