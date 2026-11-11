import haxe.io.Bytes;
import haxe.io.BytesOutput;
import haxeon.io.ByteSink;
import haxeon.io.SegmentedBytes;

/** ByteSink writes the bytes a BytesOutput would, copies what it is given unless told it may share it, and finishes into segments. */
class ByteSinkMain {
	static function main():Void {
		var sink = new ByteSink(), plain = new BytesOutput();
		plain.bigEndian = false;
		var large = Bytes.alloc(100000),
			medium = Bytes.alloc(5000),
			small = Bytes.alloc(100);
		for (index in 0...large.length)
			large.set(index, index * 7 & 0xFF);
		for (index in 0...medium.length)
			medium.set(index, index * 13 & 0xFF);
		for (index in 0...small.length)
			small.set(index, index);
		sink.writeByte(5);
		plain.writeByte(5);
		sink.writeInt32(0x12345678);
		plain.writeInt32(0x12345678);
		sink.writeInt32(-2);
		plain.writeInt32(-2);
		sink.writeDouble(1.5);
		plain.writeDouble(1.5);
		sink.writeString("héllo");
		plain.writeString("héllo");
		sink.appendShared(large);
		plain.write(large);
		for (index in 0...3000) {
			sink.writeByte(index);
			plain.writeByte(index);
		}
		sink.appendShared(medium);
		plain.write(medium);
		sink.appendShared(small);
		plain.write(small);
		sink.writeBytes(large, 100, 90000);
		plain.writeBytes(large, 100, 90000);
		var result = sink.finish(), expected = plain.getBytes();
		expect(result.length == expected.length && sink.length == expected.length, "length counts everything written");
		expect(result.flatten().compare(expected) == 0, "the same bytes as BytesOutput");
		expect(result.equals(SegmentedBytes.ofBytes(expected)), "equal to the same bytes in one segment");
		var out = new BytesOutput();
		result.writeTo(out);
		expect(out.getBytes().compare(expected) == 0, "writeTo streams the same bytes");

		var copying = new ByteSink();
		copying.write(large);
		large.set(0, 255 - large.get(0));
		expect(copying.finish().flatten().get(0) != large.get(0), "write copies: changing the buffer afterwards does not change the result");
		var sharing = new ByteSink();
		sharing.appendShared(large);
		expect(sharing.finish().flatten() == large, "one shared buffer comes back as the very buffer");
		expect(new ByteSink().finish().length == 0, "nothing written is empty");

		// A shared segment between small writes must not cost a chunk each: many of them stay close to their own size.
		var many = new ByteSink();
		for (index in 0...200) {
			many.writeByte(index);
			many.appendShared(medium);
		}
		expect(many.finish().length == 200 * 5001, "interleaved writes keep all bytes");

		// Varints.
		var varints = new ByteSink();
		for (value in [0, 1, 127, 128, 300, 16383, 16384, 0x7FFFFFFF])
			varints.writeUnsignedVarint(value);
		for (value in [0, 1, -1, 63, 64, -64, -65, 8191, -8192, 2147483647, -2147483648])
			varints.writeSignedVarint(value);
		var bytes = varints.finish().flatten();
		var position = 0;
		function readUnsigned():Int {
			var value = 0, shift = 0, current;
			do {
				current = bytes.get(position++);
				value |= (current & 0x7F) << shift;
				shift += 7;
			} while ((current & 0x80) != 0);
			return value;
		}
		function readSigned():Int {
			var value = 0, shift = 0, current;
			do {
				current = bytes.get(position++);
				value |= (current & 0x7F) << shift;
				shift += 7;
			} while ((current & 0x80) != 0);
			if (shift < 32 && (current & 0x40) != 0)
				value |= -1 << shift;
			return value;
		}
		for (value in [0, 1, 127, 128, 300, 16383, 16384, 0x7FFFFFFF])
			expect(readUnsigned() == value, "unsigned varint " + value);
		for (value in [0, 1, -1, 63, 64, -64, -65, 8191, -8192, 2147483647, -2147483648])
			expect(readSigned() == value, "signed varint " + value);
		expect(position == bytes.length, "varints consume exactly their bytes");
		Sys.println("PASS: ByteSink and SegmentedBytes");
	}

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}
}
