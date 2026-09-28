// Reflect.deleteField removes a dynamic object's field and reports whether it was present.
function main():Int {
	var record:Dynamic = {};
	Reflect.setField(record, "first", 1);
	Reflect.setField(record, "second", 2);
	Reflect.setField(record, "third", 3);
	if (!Reflect.deleteField(record, "second"))
		return 1;
	if (Reflect.hasField(record, "second") || Reflect.field(record, "second") != null)
		return 2;
	if (Reflect.deleteField(record, "second") || Reflect.deleteField(record, "missing"))
		return 3;
	var fields = Reflect.fields(record);
	fields.sort(Reflect.compare);
	if (fields.join(",") != "first,third" || Std.int(Reflect.field(record, "third")) != 3)
		return 4;
	var decoded:Dynamic = haxe.Json.parse('{"keep":true,"drop":false}');
	if (!Reflect.deleteField(decoded, "drop") || Reflect.hasField(decoded, "drop") || Reflect.field(decoded, "keep") != true)
		return 5;
	return 42;
}
