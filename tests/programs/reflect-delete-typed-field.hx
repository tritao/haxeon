// Reflect.deleteField on a fixed-layout object (a typed record or a class instance) resets the field to what a
// deleted field reads as on HashLink (null, or zero for plain numbers) and reports success; hasField keeps the slot.
typedef Record = {
	var count:Int;
	var label:String;
	@:optional var weight:Null<Float>;
}

class Holder {
	public var name:String = "holder";
	public var size:Float = 2.5;

	public function new() {}

	public function describe():String
		return name;
}

function main():Int {
	var record:Record = {count: 3, label: "three", weight: 1.5};
	if (!Reflect.deleteField(record, "weight") || record.weight != null)
		return 1;
	if (!Reflect.deleteField(record, "label") || record.label != null)
		return 2;
	if (!Reflect.deleteField(record, "count") || record.count != 0)
		return 3;
	if (!Reflect.hasField(record, "weight"))
		return 4;
	if (Reflect.deleteField(record, "missing"))
		return 5;
	var holder = new Holder();
	if (!Reflect.deleteField(holder, "name") || holder.name != null)
		return 6;
	if (!Reflect.deleteField(holder, "size") || holder.size != 0)
		return 7;
	// Methods are not data fields.
	if (Reflect.deleteField(holder, "describe"))
		return 8;
	return 42;
}
