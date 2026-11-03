class ReflectionAnchor {
	public var id:Int;
	public function new(id:Int) this.id = id;
}

struct ReflectionValue {
	public var number:Int;
	public var anchor:ReflectionAnchor;
	public function new(number:Int, anchor:ReflectionAnchor) {
		this.number = number;
		this.anchor = anchor;
	}
}

class ReflectionBox<T> {
	public var value:T;
	public function new(value:T) this.value = value;
}

function main():Int {
	var anchor = new ReflectionAnchor(7);
	var box = new ReflectionBox<ReflectionValue>(new ReflectionValue(35, anchor));
	var snapshot:ReflectionValue = cast Reflect.field(box, "value");
	if (snapshot.number != 35 || snapshot.anchor != anchor) return 1;
	snapshot.number = 1;
	if (box.value.number != 35) return 2;
	Reflect.setField(box, "value", new ReflectionValue(36, anchor));
	if (box.value.number != 36 || box.value.anchor != anchor) return 3;
	var rejected = false;
	try Reflect.setField(box, "value", 123) catch (_:Dynamic) rejected = true;
	if (!rejected || box.value.number != 36) return 4;
	rejected = false;
	try Reflect.setField(box, "value", null) catch (_:Dynamic) rejected = true;
	if (!rejected || box.value.number != 36) return 5;
	var optional = new ReflectionBox<Null<ReflectionValue>>(null);
	Reflect.setField(optional, "value", new ReflectionValue(8, anchor));
	var saved = optional.value;
	if (saved == null || saved.number != 8 || saved.anchor != anchor) return 6;
	rejected = false;
	try Reflect.setField(optional, "value", 123) catch (_:Dynamic) rejected = true;
	saved = optional.value;
	if (!rejected || saved == null || saved.number != 8) return 7;
	Reflect.setField(optional, "value", null);
	if (optional.value != null || Reflect.field(optional, "value") != null) return 8;
	return box.value.number + box.value.anchor.id - 1;
}
