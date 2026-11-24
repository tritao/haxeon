class Items<T> {
	final items:Array<T>;

	public function new(items:Array<T>)
		this.items = items;

	public function iterator():Iterator<T>
		return items.iterator();

	public function first():{item:T} return {item: items[0]};
}

class Main {
	static function show<T>(items:Items<T>):String {
		var parts = [];
		for (item in items)
			parts.push(Std.string(item));
		return parts.join(",") + " first " + items.first().item;
	}

	static function main() {
		Sys.println(show(new Items(["a", "b"])));
		Sys.println(show(new Items([1, 2, 3])));
		Sys.println(show(new Items([0.5])));
		for (item in new Items([true, false]))
			Sys.println(item);
	}
}
