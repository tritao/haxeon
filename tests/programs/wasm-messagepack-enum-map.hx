import haxeon.wire.MessagePack;
import haxeon.wire.MessagePackWriter;

@:wire
enum WasmWireKind {
	@:id(7)
	Left;
	@:id(3)
	Right;
}

function main():Int {
	var first:Map<WasmWireKind, Int> = new Map<WasmWireKind, Int>();
	first.set(Left, 7);
	first.set(Right, 3);
	var second:Map<WasmWireKind, Int> = new Map<WasmWireKind, Int>();
	second.set(Right, 3);
	second.set(Left, 7);
	var firstBytes = MessagePack.encode(first),
		secondBytes = MessagePack.encode(second);
	if (firstBytes.compare(secondBytes) != 0)
		return 0;

	var restored:Map<WasmWireKind, Int> = MessagePack.decode(firstBytes);
	if (restored.get(Left) != 7 || restored.get(Right) != 3 || restored.size() != 2)
		return 0;
	var total = 0, count = 0;
	for (kind => amount in restored) {
		if (kind != Left && kind != Right)
			return 0;
		total += amount;
		count++;
	}
	if (count != 2 || total != 10)
		return 0;

	var unknown = new MessagePackWriter();
	unknown.writeMapHeader(1);
	unknown.writeInt(99);
	unknown.writeInt(1);
	var unknownRejected = false;
	try {
		var ignoredUnknown:Map<WasmWireKind, Int> = MessagePack.decode(unknown.getBytes());
	} catch (_:Dynamic) {
		unknownRejected = true;
	}
	if (!unknownRejected)
		return 0;

	var nonInteger = new MessagePackWriter();
	nonInteger.writeMapHeader(1);
	nonInteger.writeString("bad");
	nonInteger.writeInt(1);
	var nonIntegerRejected = false;
	try {
		var ignoredNonInteger:Map<WasmWireKind, Int> = MessagePack.decode(nonInteger.getBytes());
	} catch (_:Dynamic) {
		nonIntegerRejected = true;
	}
	if (!nonIntegerRejected)
		return 0;

	var duplicate = new MessagePackWriter();
	duplicate.writeMapHeader(2);
	duplicate.writeInt(7);
	duplicate.writeInt(1);
	duplicate.writeInt(7);
	duplicate.writeInt(9);
	var duplicateDecoded:Map<WasmWireKind, Int> = MessagePack.decode(duplicate.getBytes());
	return duplicateDecoded.size() == 1 && duplicateDecoded.get(Left) == 9 ? 42 : 0;
}
