// A String reflects as stock Haxe's: its data and length, never the hash string maps keep in it.
function main():Int {
	var text:Dynamic = "ab" + "c";
	var keys:Map<String, Int> = [];
	keys.set(text, 1);
	return Reflect.fields(text).join(",") == "bytes,length"
		&& !Reflect.hasField(text, "hash")
		&& Reflect.field(text, "length") == 3
		&& keys.get("abc") == 1 ? 42 : 1;
}
