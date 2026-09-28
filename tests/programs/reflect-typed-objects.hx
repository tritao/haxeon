// Reflect reads and writes compiled class and anonymous record fields by name on every target.
class Base {
	public var id:Int;

	public function new()
		id = 7;
}

class Derived extends Base {
	public var label:String;

	public function new() {
		super();
		label = "derived";
	}
}

function main():Int {
	var record:Dynamic = true ? {answer: 42, name: "record"} : null;
	if (!Reflect.hasField(record, "answer") || Std.int(Reflect.field(record, "answer")) != 42 || Reflect.hasField(record, "missing"))
		return 1;
	var derived:Dynamic = new Derived();
	if (Std.int(Reflect.field(derived, "id")) != 7 || Reflect.field(derived, "label") != "derived")
		return 2;
	var fields = Reflect.fields(derived);
	fields.sort(Reflect.compare);
	if (fields.join(",") != "id,label")
		return 3;
	Reflect.setField(derived, "id", 9);
	Reflect.setField(record, "name", "renamed");
	if (Std.int(Reflect.field(derived, "id")) != 9 || Reflect.field(record, "name") != "renamed")
		return 4;
	return Reflect.field(derived, "missing") == null ? 42 : 5;
}
