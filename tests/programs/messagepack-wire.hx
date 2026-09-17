import haxe.Int64;
import haxe.io.Bytes;
import haxe.wire.MessagePack;
import haxe.wire.MessagePackCodec;
import haxe.wire.MessagePackFrame;
import haxe.wire.MessagePackReader;
import haxe.wire.MessagePackWriter;

@:wire
class WireNumbers {
	@:id(1)
	public var small:Int64;
	@:id(2)
	public var large:Int64;
	@:id(3)
	public var values:Array<Int64>;
	@:id(4)
	public var byName:Map<String, Int64>;
}

class OpaqueValue {
	public var text:String;

	public function new(text:String) {
		this.text = text;
	}
}

class OpaqueValueCodec implements MessagePackCodec<OpaqueValue> {
	public function new() {}

	public function encode(writer:MessagePackWriter, value:OpaqueValue):Void {
		writer.writeMapHeader(1);
		writer.writeString("text");
		writer.writeString(value.text);
	}

	public function decode(reader:MessagePackReader):OpaqueValue {
		var text = "";
		var count = reader.readMapHeader();
		for (_ in 0...count) {
			if (reader.readString() == "text")
				text = reader.readString();
			else
				reader.skip();
		}
		return new OpaqueValue(text);
	}
}

function main():Int {
	var maximum = Int64.parseString("9223372036854775807"),
		minimum = Int64.parseString("-9223372036854775808");
	var writer = new MessagePackWriter();
	writer.writeInt64(Int64.ofInt(0));
	writer.writeInt64(Int64.ofInt(-1));
	writer.writeInt64(Int64.ofInt(2147483647));
	writer.writeInt64(Int64.ofInt(-2147483648));
	writer.writeInt64(maximum);
	writer.writeInt64(minimum);
	if (!sameBytes(writer.getBytes(), [
		0x00, 0xff, 0xce, 0x7f, 0xff, 0xff, 0xff, 0xd2, 0x80, 0x00, 0x00, 0x00, 0xd3, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xd3, 0x80, 0x00, 0x00,
		0x00, 0x00, 0x00, 0x00, 0x00
	]))
		return 1;

	var reader = new MessagePackReader(writer.getBytes());
	if (Int64.compare(reader.readInt64(), Int64.ofInt(0)) != 0
		|| Int64.compare(reader.readInt64(), Int64.ofInt(-1)) != 0
		|| Int64.compare(reader.readInt64(), Int64.ofInt(2147483647)) != 0
		|| Int64.compare(reader.readInt64(), Int64.ofInt(-2147483648)) != 0
		|| Int64.compare(reader.readInt64(), maximum) != 0
		|| Int64.compare(reader.readInt64(), minimum) != 0)
		return 2;
	if (!reader.atEnd())
		return 3;
	var uint32Maximum = Int64.parseString("4294967295"),
		uint32Writer = new MessagePackWriter();
	uint32Writer.writeInt64(Int64.parseString("2147483648"));
	uint32Writer.writeInt64(uint32Maximum);
	if (!sameBytes(uint32Writer.getBytes(), [0xce, 0x80, 0x00, 0x00, 0x00, 0xce, 0xff, 0xff, 0xff, 0xff]))
		return 17;
	var uint32Reader = new MessagePackReader(uint32Writer.getBytes());
	if (Int64.compare(uint32Reader.readInt64(), Int64.parseString("2147483648")) != 0
		|| Int64.compare(uint32Reader.readInt64(), uint32Maximum) != 0
		|| !uint32Reader.atEnd())
		return 18;

	var unsigned32 = Bytes.alloc(9);
	unsigned32.set(0, 0xcf);
	for (index in 1...9)
		unsigned32.set(index, 0x00);
	// The following vector is deliberately rebuilt with all eight payload bytes.
	var unsignedMaximum = Bytes.alloc(9);
	unsignedMaximum.set(0, 0xcf);
	for (index in 1...5)
		unsignedMaximum.set(index, 0x00);
	for (index in 5...9)
		unsignedMaximum.set(index, 0xff);
	if (Int64.toStr(new MessagePackReader(unsignedMaximum).readInt64()) != "4294967295")
		return 4;
	if (Int64.toStr(new MessagePackReader(unsigned32).readInt64()) != "0")
		return 5;
	var unsignedTooLarge = Bytes.alloc(9);
	unsignedTooLarge.set(0, 0xcf);
	unsignedTooLarge.set(1, 0x80);
	var unsignedRejected = false;
	try
		new MessagePackReader(unsignedTooLarge).readInt64();
	catch (_:Dynamic)
		unsignedRejected = true;
	if (!unsignedRejected)
		return 6;

	var numbers = new WireNumbers();
	numbers.small = Int64.ofInt(7);
	numbers.large = maximum;
	numbers.values = [minimum, Int64.ofInt(-3)];
	numbers.byName = [];
	numbers.byName.set("max", maximum);
	numbers.byName.set("min", minimum);
	var encoded = MessagePack.encode(numbers);
	if (!sameBytes(encoded, [
		0x84, 0x01, 0x07, 0x02, 0xd3, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x03, 0x92, 0xd3, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xfd,
		0x04, 0x82, 0xa3, 0x6d, 0x61, 0x78, 0xd3, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xa3, 0x6d, 0x69, 0x6e, 0xd3, 0x80, 0x00, 0x00, 0x00, 0x00,
		0x00, 0x00, 0x00
	]))
		return 7;
	var restored:WireNumbers = MessagePack.decode(encoded);
	var restoredMax = restored.byName.get("max"),
		restoredMin = restored.byName.get("min");
	if (Int64.compare(restored.small, numbers.small) != 0
		|| Int64.compare(restored.large, numbers.large) != 0
		|| restored.values.length != 2
		|| Int64.compare(restored.values[0], minimum) != 0
		|| Int64.compare(restored.values[1], Int64.ofInt(-3)) != 0
		|| restoredMax == null
		|| restoredMin == null
		|| Int64.compare(cast restoredMax, maximum) != 0
		|| Int64.compare(cast restoredMin, minimum) != 0)
		return 8;
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
		return 9;

	var duplicate = new MessagePackWriter();
	duplicate.writeMapHeader(2);
	duplicate.writeInt(1);
	duplicate.writeInt(3);
	duplicate.writeInt(1);
	duplicate.writeInt(9);
	var duplicateDecoded:WireNumbers = MessagePack.decode(duplicate.getBytes());
	if (Int64.compare(duplicateDecoded.small, Int64.ofInt(9)) != 0)
		return 10;

	var trailing = appendByte(encoded, 0xc0), trailingRejected = false;
	try {
		var ignored:WireNumbers = MessagePack.decode(trailing);
	} catch (_:Dynamic) {
		trailingRejected = true;
	}
	if (!trailingRejected)
		return 11;

	var framed = MessagePackFrame.pack(encoded);
	var unframed = MessagePackFrame.unpack(framed);
	if (unframed.compare(encoded) != 0)
		return 12;
	var badVersion = copyBytes(framed);
	badVersion.set(4, 2);
	var versionRejected = false;
	try {
		MessagePackFrame.unpack(badVersion);
	} catch (_:Dynamic) {
		versionRejected = true;
	}
	if (!versionRejected)
		return 13;
	var framedTrailingRejected = false;
	try {
		MessagePackFrame.unpack(appendByte(framed, 0));
	} catch (_:Dynamic) {
		framedTrailingRejected = true;
	}
	if (!framedTrailingRejected)
		return 14;

	var codec:MessagePackCodec<OpaqueValue> = new OpaqueValueCodec(),
		opaque = new OpaqueValue("custom");
	var customBytes = MessagePack.encodeWith(opaque, codec);
	var custom:OpaqueValue = MessagePack.decodeWith(customBytes, codec);
	if (custom.text != "custom")
		return 15;
	var customTrailingRejected = false;
	try {
		var ignoredCustom:OpaqueValue = MessagePack.decodeWith(appendByte(customBytes, 0xc0), codec);
	} catch (_:Dynamic) {
		customTrailingRejected = true;
	}
	return customTrailingRejected ? 42 : 16;
}

function appendByte(bytes:Bytes, value:Int):Bytes {
	var result = Bytes.alloc(bytes.length + 1);
	for (index in 0...bytes.length)
		result.set(index, bytes.get(index));
	result.set(bytes.length, value);
	return result;
}

function copyBytes(bytes:Bytes):Bytes {
	var result = Bytes.alloc(bytes.length);
	for (index in 0...bytes.length)
		result.set(index, bytes.get(index));
	return result;
}

function sameBytes(actual:Bytes, expected:Array<Int>):Bool {
	if (actual.length != expected.length)
		return false;
	for (index in 0...expected.length)
		if (actual.get(index) != expected[index])
			return false;
	return true;
}
