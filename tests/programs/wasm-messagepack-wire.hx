import haxe.Int64;
import haxe.wire.MessagePack;
import haxe.wire.MessagePackWriter;

@:wire
class WasmWireNumbers {
	@:id(1)
	public var small:Int64;
	@:id(2)
	public var large:Int64;
	@:id(3)
	public var values:Array<Int64>;
	@:id(4)
	public var byName:Map<String, Int64>;
}

function main():Int {
	var maximum = Int64.make(0x7fffffff, -1),
		minimum = Int64.make(-2147483648, 0);
	var value = new WasmWireNumbers();
	value.small = Int64.ofInt(7);
	value.large = maximum;
	value.values = [minimum, Int64.ofInt(-3)];
	value.byName = [];
	value.byName.set("max", maximum);
	value.byName.set("min", minimum);
	var bytes = MessagePack.encode(value);
	if (!sameBytes(bytes, [
		0x84, 0x01, 0x07, 0x02, 0xd3, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x03, 0x92, 0xd3, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xfd,
		0x04, 0x82, 0xa3, 0x6d, 0x61, 0x78, 0xd3, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xa3, 0x6d, 0x69, 0x6e, 0xd3, 0x80, 0x00, 0x00, 0x00, 0x00,
		0x00, 0x00, 0x00
	]))
		return 0;
	var restored:WasmWireNumbers = MessagePack.decode(bytes);
	var restoredMax = restored.byName.get("max"),
		restoredMin = restored.byName.get("min");
	if (Int64.compare(restored.small, Int64.ofInt(7)) != 0
		|| Int64.compare(restored.large, maximum) != 0
		|| restored.values.length != 2
		|| Int64.compare(restored.values[0], minimum) != 0
		|| Int64.compare(restored.values[1], Int64.ofInt(-3)) != 0
		|| restoredMax == null
		|| restoredMin == null
		|| Int64.compare(cast restoredMax, maximum) != 0
		|| Int64.compare(cast restoredMin, minimum) != 0)
		return 0;
	var byId:Map<Int, Int64> = [];
	byId.set(-1, minimum);
	byId.set(7, maximum);
	var restoredById:Map<Int, Int64> = MessagePack.decode(MessagePack.encode(byId)),
		restoredByIdMinimum = restoredById.get(-1),
		restoredByIdMaximum = restoredById.get(7);
	if (restoredByIdMinimum == null
		|| restoredByIdMaximum == null
		|| Int64.compare(cast restoredByIdMinimum, minimum) != 0
		|| Int64.compare(cast restoredByIdMaximum, maximum) != 0)
		return 0;
	var writer = new MessagePackWriter();
	writer.writeInt64(maximum);
	writer.writeInt64(minimum);
	return writer.byteLength() == 18 ? 42 : 0;
}

function sameBytes(actual:haxe.io.Bytes, expected:Array<Int>):Bool {
	if (actual.length != expected.length)
		return false;
	for (index in 0...expected.length)
		if (actual.get(index) != expected[index])
			return false;
	return true;
}
