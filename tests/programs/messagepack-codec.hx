import haxe.io.Bytes;
import haxe.wire.MessagePackCodec;
import haxe.wire.MessagePackReader;
import haxe.wire.MessagePackWriter;

function main():Int {
	var integers = new MessagePackWriter();
	integers.writeInt(0);
	integers.writeInt(127);
	integers.writeInt(128);
	integers.writeInt(300);
	integers.writeInt(-1);
	integers.writeInt(-32);
	integers.writeInt(-33);
	integers.writeInt(-129);
	integers.writeInt(-40000);
	if (!sameBytes(integers.getBytes(), [
		0x00, 0x7f, 0xcc, 0x80, 0xcd, 0x01, 0x2c, 0xff, 0xe0, 0xd0, 0xdf, 0xd1, 0xff, 0x7f, 0xd2, 0xff, 0xff, 0x63, 0xc0
	]))
		return 1;

	var shortString = new MessagePackWriter();
	shortString.writeString("1234567890123456");
	if (shortString.getBytes().get(0) != 0xb0)
		return 2;
	var float32 = Bytes.alloc(5);
	float32.set(0, 0xca);
	float32.set(1, 0x3f);
	float32.set(2, 0xc0);
	float32.set(3, 0x00);
	float32.set(4, 0x00);
	if (new MessagePackReader(float32).readFloat() != 1.5)
		return 3;
	var extensionWriter = new MessagePackWriter();
	extensionWriter.writeExtension(7, Bytes.ofString("x"));
	var extension = new MessagePackReader(extensionWriter.getBytes()).readExtension();
	if (extension.type != 7 || extension.value.toString() != "x")
		return 4;
	var codec:MessagePackCodec<Int> = new IntMessagePackCodec();
	var codecWriter = new MessagePackWriter();
	codec.encode(codecWriter, 1234);
	if (codec.decode(new MessagePackReader(codecWriter.getBytes())) != 1234)
		return 18;

	var writer = new MessagePackWriter();
	writer.writeMapHeader(6);
	writer.writeString("number");
	writer.writeInt(300);
	writer.writeString("negative");
	writer.writeInt(-40000);
	writer.writeString("float");
	writer.writeFloat(1.5);
	writer.writeString("text");
	writer.writeString("Olá 😀");
	writer.writeString("items");
	writer.writeArrayHeader(3);
	writer.writeBool(true);
	writer.writeNil();
	writer.writeInt(-7);
	writer.writeString("bytes");
	writer.writeBinary(Bytes.ofString("raw"));

	var bytes = writer.getBytes();
	var reader = new MessagePackReader(bytes);
	if (reader.readMapHeader() != 6)
		return 5;
	if (reader.readString() != "number" || reader.readInt() != 300)
		return 6;
	if (reader.readString() != "negative" || reader.readInt() != -40000)
		return 7;
	if (reader.readString() != "float" || reader.readFloat() != 1.5)
		return 8;
	if (reader.readString() != "text" || reader.readString() != "Olá 😀")
		return 9;
	if (reader.readString() != "items" || reader.readArrayHeader() != 3)
		return 10;
	if (!reader.readBool())
		return 11;
	reader.readNil();
	if (reader.readInt() != -7)
		return 12;
	if (reader.readString() != "bytes" || reader.readBinary().toString() != "raw")
		return 13;
	if (!reader.atEnd())
		return 14;

	var unknown = new MessagePackWriter();
	unknown.writeMapHeader(1);
	unknown.writeString("ignored");
	unknown.writeArrayHeader(3);
	unknown.writeInt(1);
	unknown.writeInt(2);
	unknown.writeInt(3);
	unknown.writeString("tail");
	var skipReader = new MessagePackReader(unknown.getBytes());
	skipReader.skip();
	if (skipReader.readString() != "tail" || !skipReader.atEnd())
		return 15;

	var limited = false;
	try {
		new MessagePackReader(bytes, 2).readMapHeader();
	} catch (_:Dynamic) {
		limited = true;
	}
	if (limited)
		return 16;

	return bytes.length > 0 && writer.byteLength() == bytes.length ? 42 : 17;
}

function sameBytes(actual:Bytes, expected:Array<Int>):Bool {
	if (actual.length != expected.length)
		return false;
	for (index in 0...expected.length)
		if (actual.get(index) != expected[index])
			return false;
	return true;
}

class IntMessagePackCodec implements MessagePackCodec<Int> {
	public function new() {}

	public function encode(writer:MessagePackWriter, value:Int):Void
		writer.writeInt(value);

	public function decode(reader:MessagePackReader):Int
		return reader.readInt();
}
