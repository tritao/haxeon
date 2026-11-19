// A String reflects as stock Haxe's: never the hash string maps keep in it. On HashLink its fields are its data and length,
// as in Haxe there; the Wasm targets reflect none.
function main():Int {
	var text:Dynamic = "ab" + "c";
	var keys:Map<String, Int> = [];
	keys.set(text, 1);
	var fields = Reflect.fields(text);
	#if !wasm
	if (fields.join(",") != "bytes,length")
		return 1;
	#end
	return fields.indexOf("hash") < 0
		&& !Reflect.hasField(text, "hash")
		&& Reflect.field(text, "length") == 3
		&& keys.get("abc") == 1 ? 42 : 1;
}
