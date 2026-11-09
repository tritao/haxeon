package haxeon.io;

import haxe.io.Bytes;

/**
 * Where an encoder puts bytes. Writes copy into chunks that are never reallocated, so a hundred-megabyte result costs about itself in
 * allocation instead of a doubling buffer plus a final copy. `appendShared` takes a whole `Bytes` by reference instead of copying it, for
 * data the caller guarantees is never changed afterwards (an encoding a cache keeps, a source file's contents); the result is a
 * `SegmentedBytes` that refers to such data without a copy. Integers and floats are little endian.
 */
final class ByteSink {
	static inline final FIRST_CHUNK = 256;
	static inline final MAX_CHUNK = 262144;
	static inline final SHARED_MINIMUM = 4096;
	static final NONE = Bytes.alloc(0);
	static final scratch = Bytes.alloc(8);

	var segments:Array<Bytes> = [];
	var lengths:Array<Int> = [];
	var total = 0;
	var chunk:Bytes = NONE;
	var used = 0;
	var nextChunk = FIRST_CHUNK;

	public function new() {}

	/** Bytes written so far. */
	public var length(get, never):Int;

	function get_length():Int
		return total + used;

	function closeChunk():Void {
		if (used == 0)
			return;
		segments.push(chunk);
		lengths.push(used);
		total += used;
		chunk = NONE;
		used = 0;
	}

	/** Room for the next write, in a chunk allocated only when something is written to it. */
	inline function room():Void {
		if (used == chunk.length) {
			closeChunk();
			chunk = Bytes.alloc(nextChunk);
			if (nextChunk < MAX_CHUNK)
				nextChunk *= 2;
		}
	}

	public function writeByte(value:Int):Void {
		room();
		chunk.set(used++, value);
	}

	/** Copies `count` bytes of `source` from `position`. */
	public function writeBytes(source:Bytes, position:Int, count:Int):Void {
		if (position < 0 || count < 0 || position + count > source.length)
			throw "ByteSink.writeBytes is outside the source";
		var remaining = count, from = position;
		while (remaining > 0) {
			room();
			var take = chunk.length - used;
			if (take > remaining)
				take = remaining;
			chunk.blit(used, source, from, take);
			used += take;
			from += take;
			remaining -= take;
		}
	}

	/** Copies all of `source`. */
	public function write(source:Bytes):Void
		writeBytes(source, 0, source.length);

	/**
	 * Appends `source` without copying it. The caller guarantees that its bytes are never changed again, because the result and
	 * every other byte string built from it share them. Short buffers are copied: a segment costs more than the copy.
	 */
	public function appendShared(source:Bytes):Void {
		if (source.length < SHARED_MINIMUM) {
			writeBytes(source, 0, source.length);
			return;
		}
		closeChunk();
		// The writes after a shared segment start with a small chunk again: a full-sized one would mostly stay empty.
		nextChunk = FIRST_CHUNK;
		segments.push(source);
		lengths.push(source.length);
		total += source.length;
	}

	/** Appends the segments of `other` (shared, not copied). */
	public function appendSegments(other:SegmentedBytes):Void {
		for (index in 0...other.segmentCount) {
			var bytes = other.segmentBytes(index), count = other.segmentLength(index);
			if (count == bytes.length)
				appendShared(bytes);
			else
				writeBytes(bytes, 0, count);
		}
	}

	public function writeInt32(value:Int):Void {
		scratch.set(0, value & 0xFF);
		scratch.set(1, (value >> 8) & 0xFF);
		scratch.set(2, (value >> 16) & 0xFF);
		scratch.set(3, (value >>> 24) & 0xFF);
		writeBytes(scratch, 0, 4);
	}

	public function writeDouble(value:Float):Void {
		scratch.setDouble(0, value);
		writeBytes(scratch, 0, 8);
	}

	/** The UTF-8 bytes of `text`. */
	public function writeString(text:String):Void
		write(Bytes.ofString(text));

	/** An unsigned LEB128 integer. */
	public function writeUnsignedVarint(value:Int):Void {
		var rest = value;
		while (rest >= 0x80 || rest < 0) {
			writeByte((rest & 0x7F) | 0x80);
			rest >>>= 7;
		}
		writeByte(rest);
	}

	/** A signed LEB128 integer. */
	public function writeSignedVarint(value:Int):Void {
		var rest = value, more = true;
		while (more) {
			var low = rest & 0x7F;
			rest >>= 7;
			if ((rest == 0 && (low & 0x40) == 0) || (rest == -1 && (low & 0x40) != 0))
				more = false;
			else
				low |= 0x80;
			writeByte(low);
		}
	}

	/** Everything written, as an immutable byte string. The sink can still be written to; later writes are not part of the result. */
	public function finish():SegmentedBytes {
		closeChunk();
		return total == 0 ? SegmentedBytes.EMPTY : new SegmentedBytes(segments.copy(), lengths.copy(), total);
	}
}
