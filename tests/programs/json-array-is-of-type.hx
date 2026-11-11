import haxe.Json;
import haxeon.wire.JsonWire;

@:wire
class Record {
	@:id(1) public var items:Array<Int>;

	public function new(items:Array<Int>)
		this.items = items;
}

function main():Int {
	var raw:Dynamic = Json.parse('[{"value":42}]');
	if (!Std.isOfType(raw, Array))
		return 1;
	var parsed:Dynamic = Reflect.field(Json.parse('{"items":[{"value":42}]}'), "items");
	if (!Std.isOfType(parsed, Array))
		return 2;
	var record:Record = JsonWire.decode(JsonWire.encode(new Record([42])));
	var items = record.items;
	var decoded:Dynamic = items;
	if (!Std.isOfType(decoded, Array))
		return 3;
	var roundtrip:Record = JsonWire.decode(JsonWire.encode(record));
	var boxed:Dynamic = roundtrip.items;
	if (!Std.isOfType(boxed, Array))
		return 4;
	return roundtrip.items[0];
}
