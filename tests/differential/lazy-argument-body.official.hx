class Item {
	public var name:String;
	public var weight:Float;
	public var tags:Array<String>;

	public function new(name, weight, ?tags) {
		this.name = name;
		this.weight = weight;
		this.tags = tags == null ? [] : tags;
	}
}

class Main {
	static function next(x) return x + 1;

	static function half(x) return x / 2;

	static function greet(name, punctuation = "!") return "hello " + name + punctuation;

	static function total(items:Array<Item>, ?scale = 1.0) {
		var sum = 0.0;
		for (item in items)
			sum += item.weight;
		return sum * scale;
	}

	static function remember(store:Array<String>, value) store.push(value);

	static function main() {
		Sys.println(next(41));
		Sys.println(half(5));
		Sys.println(greet("you"));
		Sys.println(greet("all", "?"));
		var items = [new Item("a", 1.5), new Item("b", 2, ["heavy"])];
		Sys.println(total(items));
		Sys.println(total(items, 2));
		Sys.println(items[1].tags);
		var store = [];
		remember(store, "x");
		Sys.println(store);
	}
}
