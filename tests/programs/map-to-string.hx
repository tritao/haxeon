import haxe.ds.ObjectMap;

enum MapPrintKey #if haxeon implements Hashable #end {
	First;
	Second;
	Number(value:Int);
}

class MapPrintObject {
	final id:Int;

	public function new(id:Int)
		this.id = id;

	public function toString():String
		return "key" + id;
}

function check(actual:String, expected:String):Void {
	if (actual != expected)
		throw "expected " + expected + ", got " + actual;
}

function main():Int {
	var strings = ["b" => 2, "a" => 1];
	var ints = [8 => "eight", -2 => "minus", 1 => "one"];
	var enums = [MapPrintKey.First => "first", MapPrintKey.Second => "second", MapPrintKey.Number(3) => "three"];
	var nested:Map<String, Map<String, Int>> = ["nested" => strings];
	var nullable:Map<String, Null<Int>> = ["nil" => null, "yes" => 2];
	var empty:Map<String, Int> = [];
	var missing:Null<Map<String, Int>> = null;
	var objects = new ObjectMap<MapPrintObject, String>();
	objects.set(new MapPrintObject(2), "two");
	objects.set(new MapPrintObject(1), "one");
	var structures = new ObjectMap<{id:Int}, Int>();
	structures.set({id: 3}, 4);

	check(Std.string(strings), "[b => 2, a => 1]");
	check(strings.toString(), "[b => 2, a => 1]");
	check("map: " + strings, "map: [b => 2, a => 1]");
	check('map: $strings', "map: [b => 2, a => 1]");
	check(Std.string(ints), "[8 => eight, -2 => minus, 1 => one]");
	check(Std.string(enums), "[First => first, Second => second, Number(3) => three]");
	check(Std.string(nested), "[nested => [b => 2, a => 1]]");
	check(Std.string(nullable), "[nil => null, yes => 2]");
	check(Std.string(empty), "[]");
	check(Std.string(missing), "null");
	check(Std.string(structures), "[{id : 3} => 4]");
	check(Std.string(objects), "[key2 => two, key1 => one]");
	check(objects.toString(), "[key2 => two, key1 => one]");

	#if !wasm
	trace(strings);
	trace(ints);
	trace(enums);
	trace(nested);
	trace(nullable);
	trace(empty);
	trace(objects);
	trace(structures);
	#end
	var firstStructure = {id: 3};
	var secondStructure = {id: 3};
	structures.set(firstStructure, 5);
	structures.set(secondStructure, 6);
	if (structures.get(firstStructure) != 5 || structures.get(secondStructure) != 6)
		throw "ObjectMap must distinguish anonymous keys with equal fields";
	return 42;
}
