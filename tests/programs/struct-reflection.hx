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

class ReflectionBox {
	public var value:ReflectionValue;
	public function new(value:ReflectionValue) this.value = value;
}

class OptionalReflectionBox {
	public var value:Null<ReflectionValue>;
	public function new() value = null;
}

function main():Int {
	var anchor = new ReflectionAnchor(7);
	var box = new ReflectionBox(new ReflectionValue(35, anchor));
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
	var optional = new OptionalReflectionBox();
	if (Reflect.field(optional, "value") != null) return 6;
	Reflect.setField(optional, "value", new ReflectionValue(8, anchor));
	if (optional.value == null || optional.value.number != 8) return 7;
	var rejectedOptional = false;
	try Reflect.setField(optional, "value", 123) catch (_:Dynamic) rejectedOptional = true;
	var afterRejected = optional.value;
	if (!rejectedOptional || afterRejected == null || afterRejected.number != 8) return 9;
	Reflect.setField(optional, "value", null);
	if (optional.value != null) return 8;
	var copy:ReflectionBox = cast Reflect.copy(box);
	if (copy == box || copy.value.number != 36 || copy.value.anchor != anchor) return 10;
	Reflect.setField(copy, "value", new ReflectionValue(5, anchor));
	if (copy.value.number != 5 || box.value.number != 36) return 11;
	return box.value.number + box.value.anchor.id - 1;
}
