import haxe.Int64;
import haxe.io.Bytes;
import haxe.wire.MessagePackFrame;
import haxe.wire.MessagePackReader;
import haxe.wire.MessagePackWriter;
import sys.io.File;

typedef MessagePackVector = {
	var name:String;
	var bytes:Bytes;
}

class MessagePackInterop {
	static final vectorsPath = "tests/fixtures/messagepack-vectors.tsv";
	static final framesPath = "tests/fixtures/messagepack-frame-vectors.tsv";

	static function main():Int {
		var arguments = Sys.args();
		var canonicalVectors = arguments.length > 0 ? arguments[0] : vectorsPath;
		var externalVectors = arguments.length > 1 ? arguments[1] : null;
		var externalFrames = arguments.length > 2 ? arguments[2] : null;

		verifyVectors(readVectors(canonicalVectors), true);
		verifyFrames(readVectors(framesPath), true);
		if (externalVectors != null)
			verifyVectors(readVectors(externalVectors), false);
		if (externalFrames != null)
			verifyFrames(readVectors(externalFrames), false);
		return 42;
	}

	static function verifyVectors(vectors:Array<MessagePackVector>, canonical:Bool):Void {
		for (vector in vectors) {
			var reader = new MessagePackReader(vector.bytes);
			var writer = new MessagePackWriter();
			switch (vector.name) {
				case "nil":
					reader.readNil();
					writer.writeNil();
				case "false":
					if (reader.readBool())
						fail(vector.name, "decoded true");
					writer.writeBool(false);
				case "true":
					if (!reader.readBool())
						fail(vector.name, "decoded false");
					writer.writeBool(true);
				case "positive-fixint":
					checkInt(reader, writer, 42);
				case "negative-fixint":
					checkInt(reader, writer, -2);
				case "uint8-128":
					checkInt(reader, writer, 128);
				case "uint16-256":
					checkInt(reader, writer, 256);
				case "uint32-65536":
					checkInt(reader, writer, 65536);
				case "int8-minus-33":
					checkInt(reader, writer, -33);
				case "int16-minus-129":
					checkInt(reader, writer, -129);
				case "int32-minus-32769":
					checkInt(reader, writer, -32769);
				case "uint32-max":
					checkInt64(reader, writer, Int64.parseString("4294967295"));
				case "int64-max":
					checkInt64(reader, writer, Int64.parseString("9223372036854775807"));
				case "int64-min":
					checkInt64(reader, writer, Int64.parseString("-9223372036854775808"));
				case "float64-1.5":
					if (reader.readFloat() != 1.5)
						fail(vector.name, "decoded float differs");
					writer.writeFloat(1.5);
				case "string-hello":
					checkString(reader, writer, "hello");
				case "string-euro":
					checkString(reader, writer, "€");
				case "binary-deadbeef":
					var binary = reader.readBinary();
					if (binary.compare(bytesFromHex("deadbeef")) != 0)
						fail(vector.name, "decoded binary differs");
					writer.writeBinary(binary);
				case "array-mixed":
					if (reader.readArrayHeader() != 3)
						fail(vector.name, "decoded array length differs");
					if (reader.readInt() != 1 || reader.readInt() != -2 || reader.readString() != "x")
						fail(vector.name, "decoded array differs");
					writer.writeArrayHeader(3);
					writer.writeInt(1);
					writer.writeInt(-2);
					writer.writeString("x");
				case "map-ordered":
					if (reader.readMapHeader() != 2)
						fail(vector.name, "decoded map length differs");
					if (reader.readString() != "a" || reader.readInt() != 1 || reader.readString() != "b" || !reader.readBool())
						fail(vector.name, "decoded map differs");
					writer.writeMapHeader(2);
					writer.writeString("a");
					writer.writeInt(1);
					writer.writeString("b");
					writer.writeBool(true);
				case "string-key-utf8":
					if (reader.readMapHeader() != 3 || reader.readString() != "é" || reader.readInt() != 1 || reader.readString() != "é"
						|| reader.readInt() != 2 || reader.readString() != "😀" || reader.readInt() != 3)
						fail(vector.name, "decoded UTF-8 map ordering differs");
					writer.writeMapHeader(3);
					writer.writeString("é");
					writer.writeInt(1);
					writer.writeString("é");
					writer.writeInt(2);
					writer.writeString("😀");
					writer.writeInt(3);
				case "nested":
					if (reader.readArrayHeader() != 2 || reader.readMapHeader() != 1 || reader.readString() != "a" || reader.readInt() != 1
						|| reader.readArrayHeader() != 2 || reader.readBool() || !reader.readBool())
						fail(vector.name, "decoded nested value differs");
					writer.writeArrayHeader(2);
					writer.writeMapHeader(1);
					writer.writeString("a");
					writer.writeInt(1);
					writer.writeArrayHeader(2);
					writer.writeBool(false);
					writer.writeBool(true);
				case "ext-fixext1":
					var extension = reader.readExtension();
					if (extension.type != 42 || extension.value.compare(bytesFromHex("01")) != 0)
						fail(vector.name, "decoded extension differs");
					writer.writeExtension(42, extension.value);
				default:
					fail(vector.name, "unknown vector");
			}
			if (!reader.atEnd())
				fail(vector.name, "decoder left trailing bytes");
			if (canonical && writer.getBytes().compare(vector.bytes) != 0)
				fail(vector.name, "canonical encoding differs");
		}
	}

	static function verifyFrames(frames:Array<MessagePackVector>, canonical:Bool):Void {
		for (frame in frames) {
			var payload:Bytes;
			try {
				payload = MessagePackFrame.unpack(frame.bytes);
			} catch (error:Dynamic) {
				fail(frame.name, Std.string(error));
			}
			var payloadName = "";
			switch (frame.name) {
				case "nil-frame":
					payloadName = "nil";
				case "map-ordered-frame":
					payloadName = "map-ordered";
				default:
					fail(frame.name, "unknown frame vector");
			}
			verifyVectors([{name: payloadName, bytes: payload}], canonical);
			if (canonical && MessagePackFrame.pack(payload).compare(frame.bytes) != 0)
				fail(frame.name, "canonical frame encoding differs");
		}
	}

	static function checkInt(reader:MessagePackReader, writer:MessagePackWriter, expected:Int):Void {
		if (reader.readInt() != expected)
			fail("integer", 'decoded value differs from $expected');
		writer.writeInt(expected);
	}

	static function checkInt64(reader:MessagePackReader, writer:MessagePackWriter, expected:Int64):Void {
		if (Int64.compare(reader.readInt64(), expected) != 0)
			fail("int64", 'decoded value differs from ${Int64.toStr(expected)}');
		writer.writeInt64(expected);
	}

	static function checkString(reader:MessagePackReader, writer:MessagePackWriter, expected:String):Void {
		if (reader.readString() != expected)
			fail("string", 'decoded value differs from $expected');
		writer.writeString(expected);
	}

	static function readVectors(path:String):Array<MessagePackVector> {
		var result:Array<MessagePackVector> = [];
		for (line in File.getContent(path).split("\n")) {
			var text = StringTools.trim(line);
			if (text == "" || StringTools.startsWith(text, "#"))
				continue;
			var fields = text.split("\t");
			if (fields.length != 2)
				fail(path, "vector line must contain two tab-separated fields");
			result.push({name: fields[0], bytes: bytesFromHex(fields[1])});
		}
		return result;
	}

	static function bytesFromHex(text:String):Bytes {
		if ((text.length & 1) != 0)
			fail(text, "hex vector has odd length");
		var result = Bytes.alloc(text.length >> 1);
		for (index in 0...result.length) {
			var high = hexDigit(text.charCodeAt(index * 2));
			var low = hexDigit(text.charCodeAt(index * 2 + 1));
			result.set(index, (high << 4) | low);
		}
		return result;
	}

	static function hexDigit(code:Int):Int {
		if (code >= 48 && code <= 57)
			return code - 48;
		if (code >= 65 && code <= 70)
			return code - 55;
		if (code >= 97 && code <= 102)
			return code - 87;
		throw 'MessagePack interop failure for hex: invalid digit ${String.fromCharCode(code)}';
	}

	static function fail(vector:String, message:String):Void
		throw 'MessagePack interop failure for $vector: $message';
}
