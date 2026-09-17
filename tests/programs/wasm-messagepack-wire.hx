import haxe.Int64;
import haxe.wire.MessagePack;
import haxe.wire.MessagePackWriter;

@:wire
class WasmWireNumbers {
	@:wireId(1)
	public var small:Int64;
	@:wireId(2)
	public var large:Int64;
}

function main():Int {
	var maximum = Int64.make(0x7fffffff, -1),
		minimum = Int64.make(-2147483648, 0);
	var value = new WasmWireNumbers();
	value.small = minimum;
	value.large = maximum;
	var bytes = MessagePack.encode(value);
	var restored:WasmWireNumbers = MessagePack.decode(bytes);
	if (Int64.compare(restored.small, minimum) != 0 || Int64.compare(restored.large, maximum) != 0)
		return 0;
	var writer = new MessagePackWriter();
	writer.writeInt64(maximum);
	writer.writeInt64(minimum);
	return writer.byteLength() == 18 ? 42 : 0;
}
