import compiler.hl.ChunkedOutput;
import haxe.io.Bytes;
import haxe.io.BytesOutput;

/** ChunkedOutput writes the same bytes as BytesOutput, takes large buffers by reference, and allocates its result once. */
class ChunkedOutputMain {
	static function main():Void {
		var chunked = new ChunkedOutput(), plain = new BytesOutput();
		chunked.bigEndian = false;
		plain.bigEndian = false;
		var large = Bytes.alloc(100000), medium = Bytes.alloc(5000);
		for (index in 0...large.length)
			large.set(index, index * 7 & 0xFF);
		for (index in 0...medium.length)
			medium.set(index, index * 13 & 0xFF);
		for (output in [cast(chunked, haxe.io.Output), cast(plain, haxe.io.Output)]) {
			output.writeString("HLB");
			output.writeByte(5);
			output.writeInt32(0x12345678);
			output.writeDouble(1.5);
			if (Std.isOfType(output, ChunkedOutput))
				cast(output, ChunkedOutput).writeShared(large);
			else
				output.write(large);
			for (index in 0...3000)
				output.writeByte(index);
			output.write(medium);
			output.writeBytes(large, 100, 90000);
			output.writeBytes(large, 0, 10);
			output.write(medium);
		}
		var left = chunked.getBytes(), right = plain.getBytes();
		expect(left.length == right.length && left.compare(right) == 0, "the same bytes as BytesOutput");
		expect(chunked.length == right.length, "length counts everything written");
		var single = new ChunkedOutput();
		single.writeShared(large);
		expect(single.getBytes() == large, "one shared buffer comes back as the very buffer");
		var copied = new ChunkedOutput();
		copied.write(large);
		large.set(0, 255 - large.get(0));
		expect(copied.getBytes().get(0) != large.get(0), "write copies: changing the buffer afterwards does not change the output");
		var empty = new ChunkedOutput();
		expect(empty.getBytes().length == 0, "nothing written, nothing returned");
		Sys.println("PASS: chunked output matches BytesOutput");
	}

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}
}
