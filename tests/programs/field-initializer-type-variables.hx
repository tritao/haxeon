// A field initializer is typed in a type-variable frame of its own, as a function body is: an empty `[]` in a comprehension, and a
// lambda's own `var items = []`, are settled by what follows them there.
class Holder {
	public static var byKey:Map<String, Array<Int>> = [for (k in ["a", "b"]) k => []];
	public static var build:Void->Int = () -> {
		var items = [];
		items.push(4);
		items.push(5);
		return items.length;
	};
	public static var groups:Array<Array<String>> = [[], ["x"]];

	public var pending:Map<Int, Array<String>> = [for (index in 0...3) index => []];

	public function new() {}
}

function main():Int {
	var first = Holder.byKey.get("a");
	if (first == null)
		return 1;
	first.push(10);
	var build = Holder.build,
		holder = new Holder(),
		slot = holder.pending.get(2);
	if (slot == null)
		return 2;
	slot.push("y");
	return first[0] + build() + Holder.groups.length + slot.length + 27;
}
