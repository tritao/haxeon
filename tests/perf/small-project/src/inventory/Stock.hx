package inventory;

/** Items by name, kept in the order they were first added. */
class Stock {
	final items = new Map<String, Item>();
	final order:Array<String> = [];

	public function new() {}

	public function add(item:Item):Void {
		var existing = items.get(item.name);
		if (existing != null) {
			existing.count += item.count;
			return;
		}
		items.set(item.name, item);
		order.push(item.name);
	}

	public function remove(name:String, count:Int):Bool {
		var item = items.get(name);
		if (item == null || item.count < count)
			return false;
		item.count -= count;
		if (item.count == 0) {
			items.remove(name);
			order.remove(name);
		}
		return true;
	}

	public function list():Array<Item>
		return [for (name in order) items.get(name)];

	public function categories():Iterator<String> {
		var seen = new Map<String, Bool>();
		for (item in list())
			seen.set(item.category, true);
		var names = [for (name in seen.keys()) name];
		names.sort(Reflect.compare);
		return names.iterator();
	}

	public function total():Float
		return Lambda.fold(list(), (item, sum) -> sum + item.value(), 0.0);
}
