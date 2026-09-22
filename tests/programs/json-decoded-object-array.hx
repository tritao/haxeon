import haxe.Json;

typedef Item = {
	var id:String;
	var type:String;
}

function decodeItem(value:Dynamic):Item {
	var id:Dynamic = Reflect.field(value, "id");
	var type:Dynamic = Reflect.field(value, "type");
	if (!Std.isOfType(id, String) || !Std.isOfType(type, String))
		throw "Invalid item";
	return {id: cast id, type: cast type};
}

function main():Int {
	var parsed:Dynamic = Json.parse('[{"id":"first","type":"cad-plate"}]');
	var raw:Array<Dynamic> = cast parsed;
	var items:Array<Item> = [];
	for (value in raw)
		items.push(decodeItem(value));
	if (items.length != 1 || items[0].id != "first" || items[0].type != "cad-plate")
		return 1;
	var rejected = false;
	try
		decodeItem(Json.parse('{"id":"bad","type":7}'))
	catch (_:Dynamic)
		rejected = true;
	return rejected ? 42 : 2;
}
